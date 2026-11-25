#!/usr/bin/env bash
set -euo pipefail

WORK="${1:-${KERNEL_WORK_DIR:-$HOME/.cache/linux-saturnus-steamdeck/kernel-build}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$WORK/src"
OUT="$WORK/out"
VALVE_CONFIG="$WORK/valve-config"
SOURCE_REPO="https://github.com/evlaV/linux-integration.git"
SOURCE_COMMIT="52f69f990706fa4d0eb0dd08c1b950a42c5dacd7"
VALVE_ARCHIVE_URL="https://steamdeck-packages.steamos.cloud/archlinux-mirror/jupiter-main/os/x86_64/linux-neptune-73-7.3.1.valve3-1-x86_64.pkg.tar.zst"
LLVM_SUFFIX=""
if command -v clang-22 >/dev/null && command -v ld.lld-22 >/dev/null && command -v llvm-config-22 >/dev/null; then
  CLANG=clang-22; LLD=ld.lld-22; LLVM_CONFIG=llvm-config-22; LLVM_SUFFIX=-22
elif command -v clang >/dev/null && command -v ld.lld >/dev/null && command -v llvm-config >/dev/null; then
  CLANG=clang; LLD=ld.lld; LLVM_CONFIG=llvm-config; LLVM_SUFFIX=1
else
  echo "A matching Clang, LLD and llvm-config toolchain is required." >&2
  exit 1
fi
for tool in curl tar gzip git make sha256sum find install pahole; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

mkdir -p "$WORK" "$VALVE_CONFIG" "$OUT"
LLVM_LIBDIR="$("$LLVM_CONFIG" --libdir)"
POLLY_PLUGIN="$(find "$LLVM_LIBDIR" /usr/lib -name LLVMPolly.so -type f -print -quit 2>/dev/null || true)"
[[ -n "$POLLY_PLUGIN" ]] || { echo "LLVMPolly.so not found for $CLANG." >&2; exit 1; }
export LLVM_PLUGIN_PATH="$(dirname "$POLLY_PLUGIN")"

PAHOLE_VERSION="$(pahole --version 2>&1 | head -n 1)"
python3 - "$PAHOLE_VERSION" <<'PY'
import re, sys
match = re.search(r"(\d+)\.(\d+)", sys.argv[1])
if not match or tuple(map(int, match.groups())) < (1, 25):
    raise SystemExit(f"pahole >= 1.25 is required for kernel BTF; found {sys.argv[1]}")
PY

if [[ ! -s "$VALVE_CONFIG/config.x86_64" || ! -s "$VALVE_CONFIG/config-neptune" ]]; then
  PACKAGE="$WORK/linux-neptune-73.pkg.tar.zst"
  curl --fail --location --retry 4 "$VALVE_ARCHIVE_URL" --output "$PACKAGE"
  sha256sum "$PACKAGE" > "$VALVE_CONFIG/source-archive.sha256"
  tar --zstd -xf "$PACKAGE" -C "$VALVE_CONFIG" ./usr/lib/modules/7.3.1-valve3/build/.config
  tar --zstd -xf "$PACKAGE" -C "$VALVE_CONFIG" ./usr/lib/modules/7.3.1-valve3/build/config-neptune
  cp "$VALVE_CONFIG/usr/lib/modules/7.3.1-valve3/build/.config" "$VALVE_CONFIG/config.x86_64"
  cp "$VALVE_CONFIG/usr/lib/modules/7.3.1-valve3/build/config-neptune" "$VALVE_CONFIG/config-neptune"
fi

if [[ ! -d "$SRC/.git" ]]; then
  git clone --filter=blob:none "$SOURCE_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth=1 origin "$SOURCE_COMMIT"
git -C "$SRC" checkout --detach FETCH_HEAD
# The persistent self-hosted runner reuses this checkout. Remove patches and
# other tracked/untracked changes left by earlier preparation attempts.
git -C "$SRC" reset --hard "$SOURCE_COMMIT"
git -C "$SRC" clean -fd
ACTUAL_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
[[ "$ACTUAL_COMMIT" == "$SOURCE_COMMIT" ]] || { echo "Unexpected Valve source commit: $ACTUAL_COMMIT" >&2; exit 1; }

git -C "$SRC" apply --check "$ROOT/patches/0001-clang-polly.patch"
git -C "$SRC" apply "$ROOT/patches/0001-clang-polly.patch"
git -C "$SRC" apply --check "$ROOT/patches/0003-gud-clang-lto-overflow.patch"
git -C "$SRC" apply "$ROOT/patches/0003-gud-clang-lto-overflow.patch"
git -C "$SRC" apply --check "$ROOT/patches/0004-vangogh-4.2ghz.patch"
git -C "$SRC" apply "$ROOT/patches/0004-vangogh-4.2ghz.patch"

fetch_lkml_patch() {
  local filename="$1" url="$2" exclude="${3:-}"
  local html="$WORK/$filename.html" patch="$WORK/$filename"
  curl --fail --location --retry 4 --retry-all-errors --retry-delay 3 "$url" --output "$html"
  python3 - "$html" "$patch" <<'PY'
from html.parser import HTMLParser
import sys
class ArchiveText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
    def handle_data(self, data):
        self.parts.append(data)
parser = ArchiveText()
with open(sys.argv[1], encoding="utf-8") as source:
    parser.feed(source.read())
mail = "".join(parser.parts)
start = mail.find("diff --git ")
if start < 0:
    raise SystemExit("No unified diff found in LKML archive page")
with open(sys.argv[2], "w", encoding="utf-8") as output:
    output.write(mail[start:])
PY
  if [[ "$exclude" == "download-only" ]]; then
    return
  elif [[ -n "$exclude" ]]; then
    git -C "$SRC" apply --check --exclude="$exclude" "$patch"
    git -C "$SRC" apply --exclude="$exclude" "$patch"
  else
    git -C "$SRC" apply --check "$patch"
    git -C "$SRC" apply "$patch"
  fi
}
fetch_lkml_patch "0002-amd-pstate-epp-cache-order.patch" "https://lists.openwall.net/linux-kernel/2026/07/28/666"
fetch_lkml_patch "0003-amd-pstate-epp-boost.patch" "https://lists.openwall.net/linux-kernel/2026/07/28/678" "drivers/cpufreq/amd-pstate.h"

python3 - "$SRC/drivers/cpufreq/amd-pstate.h" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    text = source.read()
def replace_once(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one {label} anchor, found {count}")
    text = text.replace(old, new, 1)
if "#include <linux/sched/cpufreq.h>" not in text:
    replace_once("#include <linux/platform_profile.h>\n", "#include <linux/platform_profile.h>\n#include <linux/sched/cpufreq.h>\n", "sched/cpufreq include")
if "@epp_boost_update_util:" not in text:
    replace_once(" * @profile_name: Name under which @ppdev is registered\n",
                 " * @profile_name: Name under which @ppdev is registered\n"
                 " * @epp_boost_update_util: per-core EPP boost update-util hook\n"
                 " * @epp_boost_last_sample: last C0 residency sample in ns\n"
                 " * @epp_boost_last_busy: last busy sample in ns\n"
                 " * @epp_boost_active: whether per-core EPP boost is active\n"
                 " * @epp_boost_registered: whether update-util hook is registered\n", "EPP kernel-doc")
if "struct update_util_data epp_boost_update_util;" not in text:
    replace_once("\tchar *profile_name;\n",
                 "\tchar *profile_name;\n\n\t/* Per-core EPP boost state (MSR active mode). */\n"
                 "\tstruct update_util_data epp_boost_update_util;\n"
                 "\tu64 epp_boost_last_sample;\n"
                 "\tu64 epp_boost_last_busy;\n"
                 "\tbool epp_boost_active;\n"
                 "\tbool epp_boost_registered;\n", "EPP struct members")
with open(path, "w", encoding="utf-8") as output:
    output.write(text)
PY

EPP_SOURCE="$SRC/drivers/cpufreq/amd-pstate.c"
grep -Fq 'static bool epp_boost __read_mostly;' "$EPP_SOURCE"
sed -i 's/static bool epp_boost __read_mostly;/static bool epp_boost __read_mostly = true;/' "$EPP_SOURCE"

"$SRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" \
  "$VALVE_CONFIG/config.x86_64" "$VALVE_CONFIG/config-neptune" "$ROOT/config/saturnus.config"
make -C "$SRC" O="$OUT" LLVM="$LLVM_SUFFIX" CC="$CLANG" LD="$LLD" olddefconfig
"$CLANG" -march=znver2 -fsyntax-only -x c /dev/null
cp "$OUT/.config" "$WORK/resolved.config"

grep -Fq 'cpu_default_soft_max_freq = 4200;' "$SRC/drivers/gpu/drm/amd/pm/swsmu/smu11/vangogh_ppt.c"
grep -Fq 'static bool epp_boost __read_mostly = true;' "$EPP_SOURCE"
grep -Fq 'module_param_cb(epp_boost' "$EPP_SOURCE"

required=("CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" "CONFIG_LTO_CLANG_FULL=y" "CONFIG_POLLY_CLANG=y" "CONFIG_X86_AMD_PSTATE_DEFAULT_MODE=3" "CONFIG_BPF=y" "CONFIG_BPF_SYSCALL=y" "CONFIG_BPF_JIT=y" "CONFIG_BPF_JIT_ALWAYS_ON=y" "CONFIG_BPF_JIT_DEFAULT_ON=y" "CONFIG_BPF_EVENTS=y" "CONFIG_UPROBE_EVENTS=y" "CONFIG_DEBUG_KERNEL=y" "CONFIG_KALLSYMS=y" "CONFIG_KALLSYMS_ALL=y" "CONFIG_DEBUG_INFO=y" "CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y" "# CONFIG_DEBUG_INFO_REDUCED is not set" "CONFIG_DEBUG_INFO_BTF=y" "CONFIG_TRACING=y" "CONFIG_DEBUG_FS=y" "CONFIG_FTRACE=y" "CONFIG_FUNCTION_TRACER=y" "CONFIG_FTRACE_SYSCALLS=y" "CONFIG_SCHED_CLASS_EXT=y" "CONFIG_NTSYNC=y" "# CONFIG_CPU_MITIGATIONS is not set")
for setting in "${required[@]}"; do
  grep -Fqx "$setting" "$OUT/.config" || { echo "Required setting did not resolve: $setting" >&2; exit 1; }
done

# Validate every explicit disable in the Saturnus fragment, rather than
# maintaining a second hand-written list that can drift out of sync.
# Kconfig omits hidden bool/tristate symbols when they resolve to n, so an
# absent entry is valid; only an enabled y/m value is a failure.
python3 - "$ROOT/config/saturnus.config" "$OUT/.config" <<'PY'
import re, sys
fragment_path, resolved_path = sys.argv[1:]
disabled = set()
with open(fragment_path, encoding="utf-8") as fragment:
    for line in fragment:
        match = re.match(r"^\s*(?:#\s*)?CONFIG_([A-Za-z0-9_]+)(?:=n|\s+is not set)\s*$", line)
        if match:
            disabled.add(match.group(1))
resolved = {}
with open(resolved_path, encoding="utf-8") as config:
    for line in config:
        match = re.match(r"^(CONFIG_([A-Za-z0-9_]+))=([ym])$", line)
        if match:
            resolved[match.group(2)] = match.group(3)
enabled = sorted(symbol for symbol in disabled if symbol in resolved)
if enabled:
    for symbol in enabled:
        print(f"Disable request did not resolve: CONFIG_{symbol}={resolved[symbol]}", file=sys.stderr)
    raise SystemExit(1)
print(f"Validated {len(disabled)} explicit disable requests from saturnus.config.")
PY

{
  echo "Valve package: linux-neptune-73 7.3.1.valve3-1"
  echo "Source repository: $SOURCE_REPO"
  echo "Source commit: $ACTUAL_COMMIT"
  echo "Source archive SHA256: $(awk '{print $1}' "$VALVE_CONFIG/source-archive.sha256")"
  echo "Clang: $("$(command -v "$CLANG")" --version | head -n 1)"
  echo "LLD: $("$(command -v "$LLD")" --version)"
  echo "LLVM: $("$(command -v "$LLVM_CONFIG")" --version)"
  echo "Polly plugin: $POLLY_PLUGIN"
  echo "pahole: $PAHOLE_VERSION"
  echo "Polly integration: applied"
  echo "GUD Clang/LLD LTO compatibility fix: applied"
  echo "Van Gogh 4.2 GHz patch: applied"
  echo "Optimization: O2"
  echo "LTO: Full LTO"
  echo "CPU target: -march=znver2"
  echo "CPU mitigation framework: disabled"
  echo "AMD P-State default mode: active (EPP)"
  echo "Resolved configuration: $OUT/.config"
} > "$WORK/preparation-report.txt"

echo "Kernel source and Valve-based configuration prepared and validated."
echo "Source: $SRC"
echo "Output/config: $OUT"
