#!/usr/bin/env bash
# Read-only runtime diagnostics for the Saturnus Steam Deck kernel.
# Does not change settings, load modules, restart services, or reboot.
set -uo pipefail
EXPECTED_PREFIX="7.3.1-valve3-saturnus-r"
KREL="$(uname -r 2>/dev/null || printf unknown)"
CONFIG_FILE="/boot/config-$KREL"
PASS=0 WARN=0 FAIL=0 INFO=0
if [[ -r /proc/config.gz ]] && command -v zcat >/dev/null 2>&1; then CONFIG_SOURCE="/proc/config.gz"
elif [[ -r "$CONFIG_FILE" ]]; then CONFIG_SOURCE="$CONFIG_FILE"
else CONFIG_SOURCE=""; fi
pass() { printf '[ OK ] %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf '[WARN] %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '[INFO] %s\n' "$*"; INFO=$((INFO + 1)); }
section() { printf '\n== %s ==\n' "$*"; }
read_config() {
  local key="$1" line
  [[ -n "$CONFIG_SOURCE" ]] || return 1
  if [[ "$CONFIG_SOURCE" == "/proc/config.gz" ]]; then
    line="$(zcat "$CONFIG_SOURCE" 2>/dev/null | grep -m1 -E "^${key}=|^# ${key} is not set$" || true)"
  else
    line="$(grep -m1 -E "^${key}=|^# ${key} is not set$" "$CONFIG_SOURCE" 2>/dev/null || true)"
  fi
  [[ -n "$line" ]] || return 1
  case "$line" in "# $key is not set") printf 'n' ;; *=*) printf '%s' "${line#*=}" ;; *) return 1 ;; esac
}
check_config() {
  local key="$1" expected="$2" label="$3" actual
  if ! actual="$(read_config "$key")"; then warn "$label: unavailable (kernel config not readable or symbol absent)"
  elif [[ "$actual" == "$expected" ]]; then pass "$label: $actual"
  else fail "$label: expected $expected, found $actual"; fi
}
section "Saturnus kernel identity"
printf 'Kernel release : %s\n' "$KREL"
printf 'Kernel build   : %s\n' "$(uname -v 2>/dev/null || echo unavailable)"
printf 'Architecture   : %s\n' "$(uname -m 2>/dev/null || echo unavailable)"
if [[ "$KREL" == "$EXPECTED_PREFIX"* ]]; then pass "Running Saturnus kernel"
else fail "Running kernel is not a Saturnus release ($EXPECTED_PREFIX...)"; fi
if [[ -r /proc/version ]]; then printf 'Compiler/build : '; sed 's/^Linux version [^ ]* //' /proc/version
else warn "Compiler/build string unavailable"; fi
if [[ -n "$CONFIG_SOURCE" ]]; then pass "Kernel configuration source: $CONFIG_SOURCE"
else warn "Cannot read kernel configuration; config checks will be unavailable"; fi

section "Build configuration"
check_config CONFIG_CC_IS_CLANG y "Clang compiler selected"
check_config CONFIG_LTO_CLANG_FULL y "Clang Full LTO"
check_config CONFIG_POLLY_CLANG y "Polly Kconfig integration"
check_config CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE y "Performance optimization profile (O2)"
check_config CONFIG_SCHED_CLASS_EXT y "sched_ext support"
check_config CONFIG_BPF y "BPF"
check_config CONFIG_BPF_SYSCALL y "BPF syscall"
check_config CONFIG_BPF_JIT y "BPF JIT"
check_config CONFIG_DEBUG_INFO_BTF y "Kernel BTF build support"
check_config CONFIG_NTSYNC y "NTSYNC"
check_config CONFIG_X86_AMD_PSTATE_DEFAULT_MODE 3 "AMD P-State default mode (active/EPP)"
actual_mitigations="$(read_config CONFIG_CPU_MITIGATIONS 2>/dev/null || true)"
if [[ "$actual_mitigations" == n ]]; then pass "CONFIG_CPU_MITIGATIONS is disabled (as configured)"
elif [[ -n "$actual_mitigations" ]]; then fail "CONFIG_CPU_MITIGATIONS expected disabled, found $actual_mitigations"
else warn "CPU mitigation config symbol could not be read"; fi

section "CPU vulnerability and mitigation runtime"
if [[ -d /sys/devices/system/cpu/vulnerabilities ]]; then
  while IFS= read -r -d '' f; do printf '%-34s %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null || echo unreadable)"; done < <(find /sys/devices/system/cpu/vulnerabilities -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
  info "Per-vulnerability runtime reports; 'Vulnerable' is expected for some entries when mitigations are disabled."
else warn "CPU vulnerability status directory is unavailable"; fi
printf 'Kernel command line: %s\n' "$(cat /proc/cmdline 2>/dev/null || echo unavailable)"

section "AMD P-State and EPP boost"
PSTATE_STATUS="/sys/devices/system/cpu/amd_pstate/status"
if [[ -r "$PSTATE_STATUS" ]]; then
  pstate="$(cat "$PSTATE_STATUS" 2>/dev/null)"; printf 'amd_pstate status: %s\n' "$pstate"
  if [[ "$pstate" == active ]]; then pass "AMD P-State is active"; else warn "AMD P-State is not in active mode"; fi
else warn "AMD P-State status interface unavailable"; fi
EPP_BOOST=""
for f in /sys/module/amd_pstate/parameters/epp_boost /sys/module/amd_pstate/parameters/epp_boost_enable; do
  if [[ -r "$f" ]]; then EPP_BOOST="$(cat "$f" 2>/dev/null)"; printf 'EPP boost parameter (%s): %s\n' "$f" "$EPP_BOOST"; break; fi
done
case "${EPP_BOOST,,}" in
  y|1|yes|true) pass "AMD P-State EPP boost is enabled" ;;
  n|0|no|false) fail "AMD P-State EPP boost is disabled" ;;
  *) warn "EPP boost runtime parameter not exposed; cannot directly verify its state" ;;
esac
POLICY_COUNT=0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  [[ -d "$p" ]] || continue
  POLICY_COUNT=$((POLICY_COUNT + 1))
  driver="$(cat "$p/scaling_driver" 2>/dev/null || echo unknown)"
  epp="$(cat "$p/energy_performance_preference" 2>/dev/null || echo unavailable)"
  available="$(cat "$p/energy_performance_available_preferences" 2>/dev/null || true)"
  printf '%s: driver=%s; EPP=%s\n' "$(basename "$p")" "$driver" "$epp"
  [[ -z "$available" ]] || printf '  available EPP values: %s\n' "$available"
done
if (( POLICY_COUNT == 0 )); then warn "No CPU cpufreq policy interfaces found"; fi

section "sched_ext and scheduler"
SCX_STATE="/sys/kernel/sched_ext/state"; SCX_OPS="/sys/kernel/sched_ext/root/ops"
if [[ -r "$SCX_STATE" ]]; then
  scx_state="$(cat "$SCX_STATE" 2>/dev/null)"; printf 'sched_ext state: %s\n' "$scx_state"
  case "$scx_state" in enabled) pass "sched_ext is enabled" ;; disabled) warn "sched_ext support exists but sched_ext is not enabled" ;; *) info "sched_ext state: $scx_state" ;; esac
else warn "sched_ext state interface unavailable"; fi
if [[ -r "$SCX_OPS" ]]; then
  scx_ops="$(cat "$SCX_OPS" 2>/dev/null)"; printf 'sched_ext ops: %s\n' "$scx_ops"
  if [[ "$scx_ops" == *lavd* ]]; then pass "LAVD scheduler appears active"; else warn "LAVD is not reported as the active sched_ext scheduler"; fi
else warn "sched_ext active ops interface unavailable"; fi
if command -v systemctl >/dev/null 2>&1; then
  for unit in scx.service scx_loader.service; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    printf '%s: active=%s; enabled=%s\n' "$unit" "${state:-unknown}" "${enabled:-unknown}"
  done
fi
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -a -x scx_lavd 2>/dev/null; then pass "scx_lavd process is running"
  else info "No scx_lavd process found (may be managed differently or inactive)"; fi
fi

section "Runtime facilities"
if [[ -r /sys/kernel/btf/vmlinux ]]; then pass "Runtime kernel BTF is present"; else fail "Runtime kernel BTF is missing"; fi
if [[ -d /sys/fs/bpf ]]; then pass "BPF filesystem mountpoint exists"; else warn "BPF filesystem mountpoint is absent"; fi
if [[ -e /dev/ntsync ]]; then pass "NTSYNC device node exists"; else warn "NTSYNC device node is absent (may be created on demand)"; fi

section "Van Gogh frequency patch"
info "This release includes the Van Gogh CPU default soft-max change from 3500 to 4200 MHz."
info "The patched SMU default is firmware-side; generic Linux sysfs does not reliably expose it. Current cpufreq limits below do not prove the SMU soft-max value."
for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
  [[ -r "$f" ]] || continue
  khz="$(cat "$f" 2>/dev/null || true)"
  [[ "$khz" =~ ^[0-9]+$ ]] && printf '%s: %s MHz\n' "$f" "$((khz / 1000))"
done

section "Build provenance and limits"
info "Build target: x86-64 Zen 2 (-march=znver2), set by the successful Saturnus build workflow."
info "Compiler identity/version is shown in /proc/version; the kernel config confirms Clang, Full LTO and Polly integration."
info "The config cannot prove every translation unit passed through Polly; build logs are authoritative."
info "Module debug symbols were stripped during modules_install in the published build."

section "Summary"
printf 'Checks: %d OK, %d warnings, %d failures, %d informational\n' "$PASS" "$WARN" "$FAIL" "$INFO"
if (( FAIL > 0 )); then printf 'Result: one or more expected Saturnus settings/runtime facilities did not match.\n'; exit 1
elif (( WARN > 0 )); then printf 'Result: review warnings; some runtime interfaces may be unavailable or optional.\n'
else printf 'Result: all directly testable Saturnus checks passed.\n'; fi
