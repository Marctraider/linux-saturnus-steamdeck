#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-${KERNEL_WORK_DIR:-$HOME/.cache/linux-saturnus-steamdeck/kernel-build}}"
SRC="$WORK/src"
OUT="$WORK/out"
VALVE_CONFIG="$WORK/valve-config"
ARCHIVE="$WORK/linux-neptune-73-7.3.1.valve3-1.src.tar.gz"
URL="https://steamdeck-packages.steamos.cloud/archlinux-mirror/sources/jupiter-main/linux-neptune-73-7.3.1.valve3-1.src.tar.gz"
SOURCE_REPO="https://github.com/evlaV/linux-integration.git"
SOURCE_COMMIT="52f69f990706fa4d0eb0dd08c1b950a42c5dacd7"

for tool in curl tar gzip git make clang ld.lld llvm-config sha256sum find; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
[[ -f "$ROOT/config/saturnus.config" ]] || { echo "Missing config/saturnus.config" >&2; exit 1; }

LLVM_LIBDIR="$(llvm-config --libdir)"
POLLY_PLUGIN="$(find "$LLVM_LIBDIR" /usr/lib -name LLVMPolly.so -type f -print -quit 2>/dev/null || true)"
if [[ -z "$POLLY_PLUGIN" ]]; then
  echo "LLVMPolly.so is not installed for the active LLVM toolchain." >&2
  exit 1
fi
export LLVM_PLUGIN_PATH="$(dirname "$POLLY_PLUGIN")"

mkdir -p "$WORK" "$OUT" "$VALVE_CONFIG"

if [[ ! -s "$ARCHIVE" ]] || ! gzip -t "$ARCHIVE" >/dev/null 2>&1; then
  echo "Downloading/resuming Valve's linux-neptune 7.3.1.valve3 source package..."
  curl --fail --location --retry 5 --retry-delay 10 --continue-at - "$URL" --output "$ARCHIVE"
fi

if [[ ! -s "$VALVE_CONFIG/config.x86_64" || ! -s "$VALVE_CONFIG/config-neptune" ]]; then
  TMP_EXTRACT="$(mktemp -d "$WORK/config-extract.XXXXXX")"
  trap 'rm -rf "$TMP_EXTRACT"' EXIT
  echo "Extracting Valve's base and Steam Deck configuration files..."
  tar -xzf "$ARCHIVE" -C "$TMP_EXTRACT" --wildcards --no-anchored 'config.x86_64' 'config-neptune'
  BASE_CONFIG="$(find "$TMP_EXTRACT" -type f -name config.x86_64 -print -quit)"
  DECK_CONFIG="$(find "$TMP_EXTRACT" -type f -name config-neptune -print -quit)"
  [[ -n "$BASE_CONFIG" && -n "$DECK_CONFIG" ]] || {
    echo "Valve source archive did not contain both expected config files." >&2
    exit 1
  }
  install -m 0644 "$BASE_CONFIG" "$VALVE_CONFIG/config.x86_64"
  install -m 0644 "$DECK_CONFIG" "$VALVE_CONFIG/config-neptune"
  sha256sum "$ARCHIVE" > "$VALVE_CONFIG/source-archive.sha256"
fi

if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$SRC"
  git -C "$SRC" init
fi
if git -C "$SRC" remote get-url origin >/dev/null 2>&1; then
  git -C "$SRC" remote set-url origin "$SOURCE_REPO"
else
  git -C "$SRC" remote add origin "$SOURCE_REPO"
fi

echo "Fetching pinned Valve kernel source commit..."
git -C "$SRC" fetch --depth=1 origin "$SOURCE_COMMIT"
git -C "$SRC" checkout --detach --force FETCH_HEAD
git -C "$SRC" reset --hard "$SOURCE_COMMIT"
git -C "$SRC" clean -fdx
ACTUAL_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
[[ "$ACTUAL_COMMIT" == "$SOURCE_COMMIT" ]] || {
  echo "Kernel source commit mismatch: $ACTUAL_COMMIT" >&2
  exit 1
}

# Apply only the approved Polly integration and Clang/LLD LTO fix.
# The separate 4.2 GHz Van Gogh patch is intentionally not applied here.
for patch in \
  "$ROOT/patches/0001-clang-polly.patch" \
  "$ROOT/patches/0003-gud-clang-lto-overflow.patch"; do
  git -C "$SRC" apply --check "$patch"
  git -C "$SRC" apply "$patch"
done

"$SRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" \
  "$VALVE_CONFIG/config.x86_64" \
  "$VALVE_CONFIG/config-neptune" \
  "$ROOT/config/saturnus.config"

make -C "$SRC" O="$OUT" LLVM=1 CC=clang LD=ld.lld olddefconfig
clang -march=znver2 -fsyntax-only -x c /dev/null
cp "$OUT/.config" "$WORK/resolved.config"

required=(
  "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y"
  "CONFIG_LTO_CLANG_FULL=y"
  "CONFIG_POLLY_CLANG=y"
  "# CONFIG_CPU_MITIGATIONS is not set"
)
for setting in "${required[@]}"; do
  grep -Fqx "$setting" "$OUT/.config" || {
    echo "Required setting did not resolve: $setting" >&2
    exit 1
  }
done

{
  echo "Valve package: linux-neptune-73 7.3.1.valve3-1"
  echo "Source repository: $SOURCE_REPO"
  echo "Source commit: $ACTUAL_COMMIT"
  echo "Source archive SHA256: $(awk '{print $1}' "$VALVE_CONFIG/source-archive.sha256")"
  echo "Clang: $(clang --version | head -n 1)"
  echo "LLD: $(ld.lld --version)"
  echo "LLVM: $(llvm-config --version)"
  echo "Polly plugin: $POLLY_PLUGIN"
  echo "Polly integration: applied"
  echo "GUD Clang/LLD LTO compatibility fix: applied"
  echo "Van Gogh 4.2 GHz patch: not applied"
  echo "Optimization: O2"
  echo "LTO: Full LTO"
  echo "CPU target: -march=znver2"
  echo "CPU mitigation framework: disabled"
  echo "Resolved configuration: $OUT/.config"
} > "$WORK/preparation-report.txt"

echo "Kernel source and Valve-based configuration prepared and validated."
echo "Source: $SRC"
echo "Output/config: $OUT"
