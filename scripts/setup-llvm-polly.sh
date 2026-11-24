#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify runner OS." >&2
  exit 1
fi
. /etc/os-release

SUDO=()
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO=(sudo)
fi
sudo_or_root() { "${SUDO[@]}" "$@"; }

case "${ID:-}" in
  arch|cachyos)
    sudo_or_root pacman -Syu --needed --noconfirm \
      clang llvm lld polly ccache base-devel bc bison cpio pahole flex git \
      libelf ncurses openssl perl python rsync xz zstd
    CLANG="$(command -v clang)"
    LLD="$(command -v ld.lld)"
    LLVM_CONFIG="$(command -v llvm-config)"
    ;;
  ubuntu|debian)
    sudo_or_root apt-get update
    sudo_or_root apt-get install -y ca-certificates curl gnupg
    curl -fsSLo /tmp/llvm.sh https://apt.llvm.org/llvm.sh
    chmod +x /tmp/llvm.sh
    sudo_or_root /tmp/llvm.sh 22
    sudo_or_root apt-get install -y \
      clang-22 lld-22 llvm-22 llvm-22-dev libpolly-22-dev \
      build-essential ccache bc bison cpio dwarves flex git libelf-dev \
      libncurses-dev libssl-dev make perl python3 rsync xz-utils zstd
    CLANG="$(command -v clang-22)"
    LLD="$(command -v ld.lld-22)"
    LLVM_CONFIG="$(command -v llvm-config-22)"
    ;;
  *)
    echo "Unsupported self-hosted runner OS: ${PRETTY_NAME:-${ID:-unknown}}" >&2
    exit 1
    ;;
esac

LLVM_VERSION="$("$LLVM_CONFIG" --version)"
LLVM_LIBDIR="$("$LLVM_CONFIG" --libdir)"
POLLY_PLUGIN="$(find "$LLVM_LIBDIR" /usr/lib -name LLVMPolly.so -type f -print -quit 2>/dev/null || true)"
if [[ -z "$POLLY_PLUGIN" ]]; then
  echo "LLVMPolly.so not found. Ensure Polly matches LLVM $LLVM_VERSION." >&2
  exit 1
fi

export LLVM_PLUGIN_PATH="$(dirname "$POLLY_PLUGIN")"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
cat > "$TMPDIR_TEST/polly-smoke.c" <<'EOF'
int sum_array(const int *a, int n)
{
    int sum = 0;
    for (int i = 0; i < n; ++i)
        sum += a[i];
    return sum;
}
EOF

"$CLANG" -O2 -march=znver2 -fplugin=LLVMPolly.so \
  -mllvm -polly \
  -mllvm -polly-ast-use-context \
  -mllvm -polly-invariant-load-hoisting \
  -mllvm -polly-loopfusion-greedy \
  -mllvm -polly-run-inliner \
  -mllvm -polly-vectorizer=stripmine \
  -c "$TMPDIR_TEST/polly-smoke.c" -o "$TMPDIR_TEST/polly-smoke.o"

echo "Clang: $("$CLANG" --version | head -n 1)"
echo "LLD: $("$LLD" --version)"
echo "LLVM: $LLVM_VERSION"
echo "Polly plugin: $POLLY_PLUGIN"
echo "Polly compiler smoke test: passed"
