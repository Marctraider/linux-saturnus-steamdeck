# linux-saturnus-steamdeck

Compiler-optimized Steam Deck kernel with Van Gogh's low-L3-cache architecture in mind. Based on Valve's original SteamOS kernel configuration. LAVD scheduler is the only planned userspace addition.

## Source baseline

- Valve kernel source: [evlaV/linux-integration](https://github.com/evlaV/linux-integration)
- Pinned commit: `52f69f990706fa4d0eb0dd08c1b950a42c5dacd7`
- Kernel: `7.3.1-valve3`
- Base config: Valve's `config.x86_64` and `config-neptune`, layered with `config/saturnus.config`.

## Downstream patches and tunings

- **Van Gogh 4.2 GHz CPU soft maximum:** `patches/0004-vangogh-4.2ghz.patch` raises the SMU CPU soft maximum from 3500 to 4200 MHz. This raises the firmware-requested ceiling; it does not guarantee sustained 4.2 GHz operation.
- **AMD P-State active/EPP mode:** `CONFIG_X86_AMD_PSTATE_DEFAULT_MODE=3` explicitly selects active (EPP) mode. The preparation script validates that this setting survives `olddefconfig`.
- **AMD P-State per-core EPP Boost:** the preparation script ports the July 28, 2026 RFC cache-ordering and per-core boost patches (2/4 and 3/4), adapts the header additions to the pinned Valve source, and enables the feature by default. Set `amd_pstate.epp_boost=0` on the kernel command line to disable it. It requires supported MSR-based CPPC hardware.
- **Clang Polly:** `0001-clang-polly.patch` adds Polly's Kconfig and Kbuild integration.
- **GUD Full LTO compatibility:** `0003-gud-clang-lto-overflow.patch` handles the GUD fixed-size TV-mode name buffer for this Clang/LLD Full LTO build.
- **Compiler tuning:** Clang, LLD, Polly, Full LTO, O2 and `-march=znver2`.
- **CPU mitigations:** the CPU mitigation framework is disabled at compile time, as previously selected.

The AMD EPP Boost code is based on an experimental RFC, not an upstream-accepted feature. The preparation script checks patch applicability and key source symbols. The 4.2 GHz setting raises the SMU soft ceiling but is not a guarantee of actual clock behavior.

## Build process

Run `scripts/prepare-kernel.sh` to fetch the pinned Valve source, apply the downstream patches, merge Valve's two base configs with `config/saturnus.config`, run `olddefconfig`, and validate the result.

Run `scripts/build-kernel.sh` separately to compile and package. It uses the self-hosted runner, persistent 30 GiB ccache, Clang/LLD, Polly, Full LTO, O2, and `-march=znver2`. Module debug symbols are stripped during `modules_install` using `INSTALL_MOD_STRIP=1`.

The GitHub Actions workflow is manual-only (`workflow_dispatch`). Preparing or updating source does not compile a kernel. No build was started.
