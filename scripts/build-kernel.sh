#!/usr/bin/env bash
set -euo pipefail

WORK="${1:-${KERNEL_WORK_DIR:-$HOME/.cache/linux-saturnus-steamdeck/kernel-build}}"
RUN="${2:-${BUILD_RUN:-${GITHUB_RUN_NUMBER:-local}}}"
SRC="$WORK/src"
OUT="$WORK/out"
JOBS="${BUILD_JOBS:-8}"
LOCALVERSION="-saturnus-r$RUN"

[[ "$RUN" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid build identifier: $RUN" >&2; exit 1; }
[[ -s "$OUT/.config" ]] || { echo "Prepared kernel configuration not found; run prepare-kernel.sh first." >&2; exit 1; }
[[ -d "$SRC/.git" ]] || { echo "Kernel source checkout not found." >&2; exit 1; }

for tool in make clang ld.lld llvm-config ccache tar zstd sha256sum install; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

LLVM_LIBDIR="$(llvm-config --libdir)"
POLLY_PLUGIN="$(find "$LLVM_LIBDIR" /usr/lib -name LLVMPolly.so -type f -print -quit 2>/dev/null || true)"
[[ -n "$POLLY_PLUGIN" ]] || { echo "LLVMPolly.so not found." >&2; exit 1; }
export LLVM_PLUGIN_PATH="$(dirname "$POLLY_PLUGIN")"

export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/linux-saturnus-steamdeck/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-30G}"
export CCACHE_COMPRESS="${CCACHE_COMPRESS:-true}"
export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
mkdir -p "$CCACHE_DIR"

echo "Compiler cache before build:"
ccache --show-stats
ccache --zero-stats

echo "Building kernel with Clang, LLD, Polly, Full LTO, O2 and Zen 2 target..."
make -C "$SRC" O="$OUT" \
  LLVM=1 CC="ccache clang" LD=ld.lld \
  KCFLAGS="-march=znver2" LOCALVERSION="$LOCALVERSION" \
  -j"$JOBS"

RELEASE="$(make -s -C "$SRC" O="$OUT" LLVM=1 CC=clang LD=ld.lld \
  LOCALVERSION="$LOCALVERSION" kernelrelease)"
SOURCE_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
test -s "$OUT/arch/x86/boot/bzImage"
test -s "$OUT/System.map"

STAGE="${RUNNER_TEMP:-$WORK}/saturnus-package-root"
BUNDLE="${RUNNER_TEMP:-$WORK}/saturnus-install-bundle"
rm -rf "$STAGE" "$BUNDLE"
mkdir -p "$STAGE/boot" "$STAGE/usr/lib/modules" "$BUNDLE"

install -m 0644 "$OUT/arch/x86/boot/bzImage" \
  "$STAGE/boot/vmlinuz-linux-saturnus-r$RUN"
install -m 0644 "$OUT/System.map" "$STAGE/boot/System.map-$RELEASE"
install -m 0644 "$OUT/.config" "$STAGE/boot/config-$RELEASE"

# Strip module debug information at installation time, matching the
# successful previous build setup. The build tree itself remains unstripped.
make -C "$SRC" O="$OUT" LLVM=1 CC=clang LD=ld.lld \
  LOCALVERSION="$LOCALVERSION" \
  INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$STAGE" modules_install

if [[ -d "$STAGE/lib/modules/$RELEASE" ]]; then
  mv "$STAGE/lib/modules/$RELEASE" "$STAGE/usr/lib/modules/$RELEASE"
  rmdir "$STAGE/lib/modules" "$STAGE/lib" 2>/dev/null || true
fi
test -d "$STAGE/usr/lib/modules/$RELEASE"
find "$STAGE/usr/lib/modules/$RELEASE" -maxdepth 1 -type l -delete

echo "Installed stripped module tree: $(du -sh "$STAGE/usr/lib/modules/$RELEASE" | cut -f1)"
echo "Installed module count: $(find "$STAGE/usr/lib/modules/$RELEASE" -type f -name '*.ko*' | wc -l)"

tar --zstd -C "$STAGE" -cf "$BUNDLE/linux-saturnus.tar.zst" .
cat > "$BUNDLE/manifest.txt" <<EOF
kernel_release=$RELEASE
kernel_version=7.3.1-valve3
build_id=$RUN
source_commit=$SOURCE_COMMIT
kernel_image=boot/vmlinuz-linux-saturnus-r$RUN
modules=usr/lib/modules/$RELEASE
modules_install_strip=1
EOF
(cd "$BUNDLE" && sha256sum linux-saturnus.tar.zst > SHA256SUMS)

echo "Kernel release: $RELEASE"
echo "Source commit: $SOURCE_COMMIT"
echo "Bundle: $BUNDLE/linux-saturnus.tar.zst"
du -h "$BUNDLE/linux-saturnus.tar.zst"
echo "Compiler cache after build:"
ccache --show-stats
