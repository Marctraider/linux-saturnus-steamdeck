#!/usr/bin/env bash
# In-place SteamOS 3.10.x kernel replacement. Keeps Valve's existing boot paths and GRUB entry.
set -Eeuo pipefail
umask 077

REPO="Marctraider/linux-saturnus-steamdeck"
SOURCE_COMMIT="52f69f990706fa4d0eb0dd08c1b950a42c5dacd7"
BOOT_KERNEL="/boot/vmlinuz-linux-neptune-73"
BOOT_INITRAMFS="/boot/initramfs-linux-neptune-73.img"
STATE="/var/lib/linux-saturnus"
POSTBOOT="/usr/local/sbin/linux-saturnus-postboot"
UNIT="/etc/systemd/system/linux-saturnus-postboot.service"
WORK="" ROLLBACK="" TOKEN="" RELEASE="" RUN="" OLD_RELEASE=""
INSTALL_KERNEL=1
INSTALL_LAVD=1
DISABLE_LAVD=0
LAVD_MODE="--autopilot"
DISABLE_EPP_BOOST=0
EPP_SERVICE="/etc/systemd/system/linux-saturnus-epp-boost.service"
LAVD_VERSION="1.1.2.linux.steamos-2.1"
LAVD_PACKAGE_ADDED=0 LAVD_SERVICE_ENABLED_BY_US=0
LAVD_CONFIG_CHANGED=0 LAVD_CONFIG_WAS_PRESENT=0 LAVD_BACKUP_PATH=""
LAVD_SERVICE_WAS_ENABLED=0
EPP_SERVICE_CREATED=0 EPP_PREVIOUS_VALUE=""
LAVD_SERVICE_DISABLED_BY_US=0 LAVD_SERVICE_WAS_ACTIVE=0
ROOT_RO=0 ROOT_CHANGED=0 MODULES_ADDED=0 BOOT_BACKED=0

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

restore_root() {
  if (( ROOT_CHANGED && ROOT_RO )); then
    steamos-readonly enable || echo "WARNING: could not re-enable read-only mode." >&2
  fi
  ROOT_CHANGED=0
}

rollback() {
  local rc=$?
  if (( rc != 0 )); then
    if (( BOOT_BACKED )); then
      [[ ! -f "$ROLLBACK/old-kernel" ]] || install -m 0644 "$ROLLBACK/old-kernel" "$BOOT_KERNEL"
      [[ ! -f "$ROLLBACK/old-initramfs" ]] || install -m 0644 "$ROLLBACK/old-initramfs" "$BOOT_INITRAMFS"
      echo "Restored previous boot files." >&2
    fi
    rm -f "$BOOT_KERNEL.new" "$BOOT_INITRAMFS.new"
    if (( MODULES_ADDED )) && [[ -n "$RELEASE" ]]; then rm -rf -- "/usr/lib/modules/$RELEASE"; fi
    if [[ -n "$ROLLBACK" && -d "$ROLLBACK" ]]; then rm -rf -- "$ROLLBACK"; fi
    if (( LAVD_SERVICE_ENABLED_BY_US )); then systemctl disable scx.service >/dev/null 2>&1 || true; fi
    if (( LAVD_SERVICE_DISABLED_BY_US && LAVD_SERVICE_WAS_ENABLED )); then
      systemctl enable scx.service >/dev/null 2>&1 || true
      if (( LAVD_SERVICE_WAS_ACTIVE )); then systemctl start scx.service >/dev/null 2>&1 || true; fi
    fi
    if (( EPP_SERVICE_CREATED )); then systemctl disable linux-saturnus-epp-boost.service >/dev/null 2>&1 || true; rm -f "$EPP_SERVICE"; systemctl daemon-reload >/dev/null 2>&1 || true; fi
    if [[ -n "$EPP_PREVIOUS_VALUE" && -w /sys/module/amd_pstate/parameters/epp_boost ]]; then printf "%s\n" "$EPP_PREVIOUS_VALUE" > /sys/module/amd_pstate/parameters/epp_boost || true; fi
    if (( LAVD_CONFIG_CHANGED )); then
      if (( LAVD_CONFIG_WAS_PRESENT )) && [[ -e "$WORK/scx-default.original" ]]; then
        install -m 0644 "$WORK/scx-default.original" /etc/default/scx
      else
        rm -f /etc/default/scx
      fi
    fi
    if (( LAVD_PACKAGE_ADDED )); then pacman -Rns --noconfirm scx-scheds >/dev/null 2>&1 || true; fi
    [[ -z "$LAVD_BACKUP_PATH" ]] || rm -f "$LAVD_BACKUP_PATH"
    rm -f "$STATE/pending-release" "$STATE/previous-release" "$STATE/rollback-dir" "$POSTBOOT" "$UNIT"
    systemctl disable linux-saturnus-postboot.service >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    [[ -z "$WORK" || ! -d "$WORK" ]] || rm -rf -- "$WORK"
  fi
  restore_root
  return "$rc"
}

get_token() {
  local t=""
  t="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -z "$t" ]] && command -v gh >/dev/null 2>&1; then t="$(gh auth token 2>/dev/null || true)"; fi
  if [[ -z "$t" && -n "$(printenv SUDO_USER 2>/dev/null || true)" ]] && command -v sudo >/dev/null 2>&1; then
    t="$(sudo -u "$(printenv SUDO_USER)" gh auth token 2>/dev/null || true)"
  fi
  printf '%s' "$t"
}

api_get() {
  local url="$1" output="$2"
  local -a auth=()
  [[ -z "$TOKEN" ]] || auth=(-H "Authorization: Bearer $TOKEN")
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
    --proto '=https' --proto-redir '=https' \
    "${auth[@]}" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: linux-saturnus-installer" --output "$output" "$url"
}

fetch_bundle() {
  local release_api="https://api.github.com/repos/$REPO/releases/latest"
  api_get "$release_api" "$WORK/release.json" || die "Cannot read the latest GitHub Release. For a public install, make the repository public; for a private install, provide GH_TOKEN."
  mapfile -t asset_urls < <(python3 - "$WORK/release.json" <<'PY'
import json,re,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
tag=d.get("tag_name","")
if not re.fullmatch(r"v7\.3\.1-valve3-saturnus-r[0-9]+",tag):
    raise SystemExit("Latest release has an unexpected tag")
assets=d.get("assets",[])
wanted={"linux-saturnus.tar.zst","manifest.txt","SHA256SUMS"}
by_name={a.get("name"):a.get("url") for a in assets}
if set(by_name)!=wanted or any(not by_name[n] for n in wanted):
    raise SystemExit("Latest release is missing required installer assets")
for n in ("linux-saturnus.tar.zst","manifest.txt","SHA256SUMS"):
    print(by_name[n])
PY
) || die "Latest GitHub Release is missing the expected kernel assets."
  [[ "${#asset_urls[@]}" -eq 3 ]] || die "Could not resolve all release assets."
  local names=("linux-saturnus.tar.zst" "manifest.txt" "SHA256SUMS")
  local i
  for i in 0 1 2; do
    local -a auth=()
    [[ -z "$TOKEN" ]] || auth=(-H "Authorization: Bearer $TOKEN")
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
      --proto '=https' --proto-redir '=https' \
      "${auth[@]}" -H "Accept: application/octet-stream" \
      -H "User-Agent: linux-saturnus-installer" \
      --output "$WORK/${names[$i]}" "${asset_urls[$i]}" ||
      die "Could not download release asset: ${names[$i]}"
  done
  (cd "$WORK" && sha256sum --check SHA256SUMS) || die "Release checksum mismatch."
}

read_manifest() {
  python3 - "$WORK/manifest.txt" "$SOURCE_COMMIT" > "$WORK/manifest.env" <<'PY'
import sys,re
d={}
for line in open(sys.argv[1],encoding="utf-8"):
    line=line.rstrip("\n")
    if "=" in line:
        k,v=line.split("=",1)
        if k in d: raise SystemExit("Duplicate manifest key: "+k)
        d[k]=v
keys={"kernel_release","kernel_version","build_id","source_commit","kernel_image","modules"}
if keys-d.keys(): raise SystemExit("Incomplete build manifest")
run=d["build_id"]; rel=d["kernel_release"]
if not re.fullmatch(r"[0-9]+",run): raise SystemExit("Invalid build number")
base="7.3.1-valve3-saturnus-r"+run
expected={base,base+"-g"+sys.argv[2][:12]+"-dirty"}
if rel not in expected: raise SystemExit("Unexpected kernel release")
if d["kernel_version"]!="7.3.1-valve3" or d["source_commit"]!=sys.argv[2]: raise SystemExit("Wrong source baseline")
if d["kernel_image"]!="boot/vmlinuz-linux-saturnus-r"+run: raise SystemExit("Unexpected kernel image path")
if d["modules"]!="usr/lib/modules/"+rel: raise SystemExit("Unexpected modules path")
for k in sorted(keys): print(k.upper()+"="+d[k])
PY
  # Manifest values have been constrained to the expected source and paths.
  # shellcheck disable=SC1090
  source "$WORK/manifest.env"
  RELEASE="$KERNEL_RELEASE"; RUN="$BUILD_ID"
}

extract_payload() {
  (cd "$WORK" && sha256sum --check SHA256SUMS) || die "Artifact checksum mismatch."
  tar --zstd -tf "$WORK/linux-saturnus.tar.zst" > "$WORK/archive.list"
  python3 - "$WORK/archive.list" "$RELEASE" "$RUN" <<'PY'
import pathlib,sys
names=pathlib.Path(sys.argv[1]).read_text().splitlines()
rel,run=sys.argv[2:]
kernel="boot/vmlinuz-linux-saturnus-r"+run
mods="usr/lib/modules/"+rel
sk=sm=False
for n in names:
    p=pathlib.PurePosixPath(n)
    if p.is_absolute() or ".." in p.parts: raise SystemExit("Unsafe archive path: "+n)
    clean=n.removeprefix("./")
    if clean==kernel: sk=True
    if clean.startswith(mods+"/"): sm=True
if not sk or not sm: raise SystemExit("Kernel image or module tree missing")
PY
  mkdir "$WORK/payload"
  tar --zstd --no-same-owner --no-same-permissions -xf "$WORK/linux-saturnus.tar.zst" -C "$WORK/payload"
  [[ -s "$WORK/payload/boot/vmlinuz-linux-saturnus-r$RUN" ]] || die "Kernel image missing after extraction."
  [[ -d "$WORK/payload/usr/lib/modules/$RELEASE" ]] || die "Modules missing after extraction."
  [[ -s "$WORK/payload/boot/System.map-$RELEASE" && -s "$WORK/payload/boot/config-$RELEASE" ]] || die "System.map or config missing."
  local config="$WORK/payload/boot/config-$RELEASE"
  for symbol in CONFIG_SCHED_CLASS_EXT CONFIG_BPF CONFIG_BPF_SYSCALL CONFIG_BPF_JIT CONFIG_DEBUG_INFO_BTF; do
    grep -qx "$symbol=y" "$config" || die "Install artifact lacks required sched_ext setting: $symbol=y"
  done
}

prompt_yes_no() {
  local prompt="$1" default="$2" answer=""
  local hint="[y/N]"
  [[ "$default" == "Y" ]] && hint="[Y/n]"
  [[ -r /dev/tty ]] || die "Interactive choices require a terminal (/dev/tty)."
  while true; do
    read -r -p "$prompt $hint " answer </dev/tty
    answer="${answer:-$default}"
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) echo "Please answer Y or N." >/dev/tty ;;
    esac
  done
}


prompt_lavd_options() {
  if prompt_yes_no "Enable the LAVD scheduler?" "Y"; then
    DISABLE_LAVD=0
    echo
    echo "LAVD scheduler mode"
    echo "-------------------"
    echo "1) Performance"
    echo "2) Autopilot"
    local choice=""
    while true; do
      read -r -p "Select mode [1-2]: " choice </dev/tty
      case "$choice" in
        1) LAVD_MODE="--performance"; break ;;
        2) LAVD_MODE="--autopilot"; break ;;
        *) echo "Please select 1 or 2." >/dev/tty ;;
      esac
    done
  else
    DISABLE_LAVD=1
  fi
}

prompt_options() {
  if prompt_yes_no "Install the kernel and replace the current boot files?" "Y"; then INSTALL_KERNEL=1; else INSTALL_KERNEL=0; fi
  if prompt_yes_no "Disable AMD P-State EPP boost?" "N"; then DISABLE_EPP_BOOST=1; else DISABLE_EPP_BOOST=0; fi
  if (( ! INSTALL_KERNEL )); then
    echo "Kernel replacement: No."
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help)
        cat <<'HELP'
Usage: sudo env GH_TOKEN="$(gh auth token)" bash installer.sh

The installer asks whether to replace the kernel, disable AMD P-State EPP
boost. At the end, the installer asks whether to enable LAVD and which mode to use. LAVD userspace is installed
automatically. Both EPP boost and LAVD are enabled by default.
The installer never reboots automatically.
HELP
        exit 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

install_lavd() {
  if (( ! INSTALL_KERNEL )) && [[ ! -d /sys/kernel/sched_ext ]]; then
    die "The running kernel does not expose sched_ext; install the Saturnus kernel or decline LAVD userspace."
  fi
  need pacman
  need systemctl

  if systemctl is-active --quiet scx_loader.service || systemctl is-enabled --quiet scx_loader.service; then
    die "scx_loader.service is active or enabled; refusing to enable the separate scx.service alongside it."
  fi

  if systemctl is-enabled --quiet scx.service; then LAVD_SERVICE_WAS_ENABLED=1; else LAVD_SERVICE_WAS_ENABLED=0; fi
  if systemctl is-active --quiet scx.service; then LAVD_SERVICE_WAS_ACTIVE=1; else LAVD_SERVICE_WAS_ACTIVE=0; fi

  local installed_version="" available_version=""
  if pacman -Q scx-scheds >/dev/null 2>&1; then
    installed_version="$(pacman -Q scx-scheds | awk '{print $2}')"
    echo "Using already-installed scx-scheds $installed_version; no package downgrade or replacement needed."
  else
    available_version="$(pacman -Si scx-scheds 2>/dev/null | awk -F ': *' '/^Version[[:space:]]*:/ {print $2; exit}')"
    [[ "$available_version" == "$LAVD_VERSION" ]] ||
      die "SteamOS package repository does not offer the expected scx-scheds $LAVD_VERSION (found: ${available_version:-not available}). "
    mkdir -p "$WORK/pacman-cache"
    LAVD_PACKAGE_ADDED=1
    pacman --cachedir "$WORK/pacman-cache" -S --needed --noconfirm scx-scheds
    installed_version="$(pacman -Q scx-scheds | awk '{print $2}')"
    [[ "$installed_version" == "$LAVD_VERSION" ]] || die "Unexpected installed scx-scheds version: $installed_version"
  fi

  [[ -x /usr/bin/scx_lavd ]] || die "scx-scheds did not install /usr/bin/scx_lavd."
  [[ -f /usr/lib/systemd/system/scx.service || -f /lib/systemd/system/scx.service ]] ||
    die "scx-scheds did not install the scx.service unit."

  [[ ! -L /etc/default/scx ]] || die "/etc/default/scx is a symlink; refusing to modify it."
  if [[ -e /etc/default/scx ]]; then
    cp -a /etc/default/scx "$WORK/scx-default.original"
    LAVD_CONFIG_WAS_PRESENT=1
  fi
  LAVD_CONFIG_CHANGED=1
  install -d -m 0755 /etc/default

  local lavd_help=""
  lavd_help="$(/usr/bin/scx_lavd --help 2>&1 || true)"
  grep -Fq -- "$LAVD_MODE" <<< "$lavd_help" || die "Installed LAVD does not support $LAVD_MODE."

  python3 - /etc/default/scx "$LAVD_MODE" <<'PY'
import pathlib
import re
import shlex
import sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text() if path.exists() else ""

scheduler_line = re.compile(r"(?m)^[ \t]*SCX_SCHEDULER[ \t]*=.*$")
flags_line = re.compile(r"(?m)^([ \t]*SCX_FLAGS[ \t]*=)(.*)$")

if scheduler_line.search(text):
    text = scheduler_line.sub("SCX_SCHEDULER=scx_lavd", text, count=1)
else:
    text = text.rstrip() + ("\n" if text else "") + "SCX_SCHEDULER=scx_lavd\n"

match = flags_line.search(text)
raw = match.group(2).strip() if match else ""
if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
    raw = raw[1:-1]
flags = shlex.split(raw)

conflicting = {
    "--autopilot", "--autopower", "--performance",
    "--powersave", "--balanced", "--no-core-compaction",
}
flags = [flag for flag in flags if flag not in conflicting]
flags.append(mode)

new_line = "SCX_FLAGS=" + shlex.quote(" ".join(flags))
if match:
    text = text[:match.start()] + new_line + text[match.end():]
else:
    text = text.rstrip() + ("\n" if text else "") + new_line + "\n"

path.write_text(text)
PY
  chmod 0644 /etc/default/scx

  systemctl daemon-reload
  if (( DISABLE_LAVD )); then
    if (( LAVD_SERVICE_WAS_ENABLED || LAVD_SERVICE_WAS_ACTIVE )); then LAVD_SERVICE_DISABLED_BY_US=1; fi
    systemctl disable --now scx.service >/dev/null 2>&1 || true
    echo "LAVD userspace installed (scx-scheds $installed_version); scheduler disabled."
  else
    if (( ! LAVD_SERVICE_WAS_ENABLED )); then
      systemctl enable scx.service
      LAVD_SERVICE_ENABLED_BY_US=1
    fi
    echo "LAVD userspace configured (scx-scheds $installed_version); mode: ${LAVD_MODE#--}; scx.service is enabled."
  fi
  echo "Scheduler selection takes effect on the next boot; no reboot is performed."
}

configure_epp_boost() {
  local param="/sys/module/amd_pstate/parameters/epp_boost"
  if (( DISABLE_EPP_BOOST )); then
    if [[ -r "$param" ]]; then EPP_PREVIOUS_VALUE="$(cat "$param")"; fi
    if [[ -w "$param" ]]; then
      printf '0\n' > "$param" || die "Could not disable AMD P-State EPP boost."
      [[ "$(cat "$param")" == "N" || "$(cat "$param")" == "0" ]] || die "EPP boost did not report disabled after writing."
    elif (( ! INSTALL_KERNEL )); then
      die "The running kernel does not expose a writable amd_pstate epp_boost parameter."
    fi
    cat > "$WORK/epp-boost-disable.service" <<'UNIT'
[Unit]
Description=Disable AMD P-State EPP boost for Saturnus
After=systemd-modules-load.service
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/sh -c 'test -w /sys/module/amd_pstate/parameters/epp_boost && printf 0 > /sys/module/amd_pstate/parameters/epp_boost'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    install -m 0644 "$WORK/epp-boost-disable.service" "$EPP_SERVICE"
    EPP_SERVICE_CREATED=1
    systemctl daemon-reload
    systemctl enable linux-saturnus-epp-boost.service
    echo "AMD P-State EPP boost disabled now and persistently across boots."
  else
    if [[ -w "$param" ]]; then
      printf '1\n' > "$param" || die "Could not enable AMD P-State EPP boost."
    fi
    if [[ -f "$EPP_SERVICE" ]]; then
      systemctl disable linux-saturnus-epp-boost.service >/dev/null 2>&1 || true
      rm -f "$EPP_SERVICE"
      systemctl daemon-reload
    fi
    echo "AMD P-State EPP boost remains enabled (default)."
  fi
}

persist_lavd_backup() {
  (( LAVD_CONFIG_CHANGED )) || return 0
  install -d -m 0755 "$STATE"
  if (( LAVD_CONFIG_WAS_PRESENT )); then
    LAVD_BACKUP_PATH="$STATE/scx-default.pre-lavd-r$RUN"
    install -m 0600 "$WORK/scx-default.original" "$LAVD_BACKUP_PATH"
  else
    LAVD_BACKUP_PATH="$STATE/scx-default.was-absent-r$RUN"
    : > "$LAVD_BACKUP_PATH"
    chmod 0600 "$LAVD_BACKUP_PATH"
  fi
  echo "Previous scheduler configuration saved at $LAVD_BACKUP_PATH."
}

check_platform() {
  [[ "$EUID" -eq 0 ]] || die "Run with sudo; see README for token setup."
  [[ "$(uname -m)" == "x86_64" ]] || die "Only x86_64 Steam Deck is supported."
  [[ -r /etc/os-release ]] || die "Cannot identify OS."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == steamos && "${VERSION_ID:-}" == 3.10* ]] || die "Requires SteamOS 3.10.x."
  [[ -d /sys/firmware/efi ]] || die "System is not booted via UEFI."
  mountpoint -q /efi || die "/efi is not mounted."
  [[ -f /efi/EFI/steamos/grub.cfg ]] || die "SteamOS GRUB configuration missing."
  [[ -s "$BOOT_KERNEL" && -s "$BOOT_INITRAMFS" && -s /boot/amd-ucode.img ]] || die "Expected SteamOS boot files missing."
  [[ ! -e "$STATE/pending-release" ]] || die "A previous replacement is awaiting its first boot; boot and verify it before installing another."
  [[ -d "/usr/lib/modules/$(uname -r)" ]] || die "Running kernel module tree missing."
  local ru bu wu free_kb
  ru="$(findmnt -no UUID /)"; bu="$(findmnt -no UUID /boot 2>/dev/null || true)"
  [[ -z "$bu" || "$bu" == "$ru" ]] || die "Separate /boot detected; refusing this layout."
  WORK="$(mktemp -d /var/tmp/linux-saturnus-install.XXXXXX)"
  if (( INSTALL_KERNEL )); then
    wu="$(findmnt -no UUID -T "$WORK")"
    [[ -n "$wu" && "$wu" != "$ru" ]] || die "/var/tmp must be on the large non-root filesystem."
    free_kb="$(df -Pk "$WORK" | awk 'NR==2 {print $4}')"
    (( free_kb > 1048576 )) || die "Less than 1 GiB free on staging filesystem."
    for c in curl python3 tar zstd sha256sum depmod mkinitcpio; do need "$c"; done
  elif (( INSTALL_LAVD )); then
    free_kb="$(df -Pk "$WORK" | awk 'NR==2 {print $4}')"
    (( free_kb > 65536 )) || die "Less than 64 MiB free for optional userspace package staging."
  fi
  for c in steamos-readonly findmnt mountpoint install; do need "$c"; done
  need systemctl
  need pacman
}

make_writable() {
  if findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then ROOT_RO=1; fi
  steamos-readonly disable
  ROOT_CHANGED=1
}

install_postboot() {
  cat > "$POSTBOOT" <<'POSTBOOT'
#!/usr/bin/env bash
set -Eeuo pipefail
state=/var/lib/linux-saturnus
expected="$(cat "$state/pending-release")"
rollback_dir="$(cat "$state/rollback-dir")"
if [[ "$(uname -r)" != "$expected" ]]; then
  echo "Replacement kernel is not running; keeping the recovery copy."
  exit 0
fi
root_was_readonly=0
if findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then root_was_readonly=1; fi
steamos-readonly disable
if (( root_was_readonly )); then trap 'steamos-readonly enable || true' EXIT; fi
if [[ "$rollback_dir" == /var/tmp/linux-saturnus-rollback-* ]]; then
  rm -rf -- "$rollback_dir"
fi
rm -f "$state/pending-release" "$state/previous-release" "$state/rollback-dir"
systemctl disable linux-saturnus-postboot.service
rm -f /usr/local/sbin/linux-saturnus-postboot /etc/systemd/system/linux-saturnus-postboot.service
systemctl daemon-reload
echo "New kernel confirmed; temporary recovery copies cleaned up. Previous package metadata retained."
POSTBOOT
  chmod 0755 "$POSTBOOT"
  cat > "$UNIT" <<'UNIT'
[Unit]
Description=Finalize Saturnus kernel replacement after successful SteamOS boot
After=local-fs.target
ConditionPathExists=/var/lib/linux-saturnus/pending-release

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/linux-saturnus-postboot

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable linux-saturnus-postboot.service
}

install_kernel() {
  local source="$WORK/payload/boot/vmlinuz-linux-saturnus-r$RUN"
  local module_kb free_kb
  [[ ! -e "/usr/lib/modules/$RELEASE" ]] || die "Release already exists; refusing to overwrite modules."
  module_kb="$(du -sk "$WORK/payload/usr/lib/modules/$RELEASE" | awk '{print $1}')"
  free_kb="$(df -Pk /usr/lib/modules | awk 'NR==2 {print $4}')"
  (( free_kb > module_kb + 65536 )) || die "Not enough free space on the root filesystem for the new module tree plus a 64 MiB safety margin."
  OLD_RELEASE="$(uname -r)"
  cp -a "$WORK/payload/usr/lib/modules/$RELEASE" "/usr/lib/modules/$RELEASE"
  MODULES_ADDED=1
  depmod -a "$RELEASE"
  install -m 0644 "$source" "$WORK/kernel.new"
  mkinitcpio -k "$RELEASE" -g "$WORK/initramfs.new"
  [[ -s "$WORK/initramfs.new" ]] || die "mkinitcpio did not create initramfs."

  ROLLBACK="/var/tmp/linux-saturnus-rollback-$RUN"
  [[ ! -e "$ROLLBACK" ]] || die "Rollback directory already exists: $ROLLBACK"
  mkdir -m 0700 "$ROLLBACK"
  cp -a "$BOOT_KERNEL" "$ROLLBACK/old-kernel"
  cp -a "$BOOT_INITRAMFS" "$ROLLBACK/old-initramfs"
  BOOT_BACKED=1
  install -m 0644 "$WORK/kernel.new" "$BOOT_KERNEL.new"
  install -m 0644 "$WORK/initramfs.new" "$BOOT_INITRAMFS.new"
  mv -f "$BOOT_KERNEL.new" "$BOOT_KERNEL"
  mv -f "$BOOT_INITRAMFS.new" "$BOOT_INITRAMFS"
  sync

  install -d -m 0755 "$STATE"
  printf '%s\n' "$RELEASE" > "$STATE/pending-release"
  printf '%s\n' "$OLD_RELEASE" > "$STATE/previous-release"
  printf '%s\n' "$ROLLBACK" > "$STATE/rollback-dir"
  install_postboot
  echo "Installed replacement at $BOOT_KERNEL and $BOOT_INITRAMFS."
  echo "Existing SteamOS GRUB/EFI configuration was not modified."
  echo "Previous kernel package/module tree is retained for recovery and package-manager consistency."
  echo "Reboot manually when ready; no reboot is performed."
}

main() {
  trap rollback EXIT
  parse_args "$@"
  prompt_options
  check_platform
  if (( ! INSTALL_KERNEL )); then RUN="standalone"; fi
  TOKEN="$(get_token)"
  if (( INSTALL_KERNEL )); then
    fetch_bundle
    read_manifest
    extract_payload
  fi
  make_writable
  configure_epp_boost
  if (( INSTALL_KERNEL )); then install_kernel; else echo "Skipping kernel and initramfs replacement."; fi
  prompt_lavd_options
  install_lavd
  persist_lavd_backup
  BOOT_BACKED=0; MODULES_ADDED=0
  rm -rf -- "$WORK"; WORK=""
  restore_root
}
main "$@"
