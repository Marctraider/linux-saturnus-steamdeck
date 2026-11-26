# linux-saturnus-steamdeck

Compiler-optimized Steam Deck kernel based on Valve's SteamOS kernel and configuration, with the Van Gogh APU in mind.

## Installer behavior

The installer asks three independent Y/N questions (each defaults to yes): whether to install/replace the kernel, whether to enable AMD P-State EPP boost, and whether to enable the LAVD scheduler in **Autopilot** mode.

- **AMD P-State EPP boost — Yes:** writes `1` to `/sys/module/amd_pstate/parameters/epp_boost` at runtime and adds `amd_pstate.epp_boost=1` to the SteamOS GRUB kernel command line for persistence across boots.
- **AMD P-State EPP boost — No:** writes `0` at runtime and removes the parameter from the GRUB command line.
- **LAVD — Yes:** installs/configures `scx-scheds`, enables `scx.service`, and starts or restarts it immediately when the running kernel supports `sched_ext`. If the running kernel lacks `sched_ext` (for example, before rebooting into a newly installed Saturnus kernel), the service is enabled for the next boot instead.
- **LAVD — No:** still installs/configures `scx-scheds` and its Autopilot configuration, then stops and disables `scx.service` so it remains off now and on future boots.

The installer does not reboot automatically. LAVD is a `sched_ext` userspace scheduler, so it can be started or stopped at runtime when the running kernel supports `sched_ext`; otherwise its activation waits until a compatible kernel is booted.

## Install

Run this from the directory where you want both scripts downloaded. The command downloads the installer and the read-only status checker into the current directory, then runs the installer:

```bash
curl -fL https://raw.githubusercontent.com/Marctraider/linux-saturnus-steamdeck/main/installer.sh -o installer.sh && \
curl -fL https://raw.githubusercontent.com/Marctraider/linux-saturnus-steamdeck/main/Saturnus-status.sh -o Saturnus-status.sh && \
chmod +x installer.sh Saturnus-status.sh && \
sudo bash installer.sh
```

After installing the kernel and rebooting into it, run the status checker from that same directory:

```bash
./Saturnus-status.sh
```

The status checker is read-only. It reports the running kernel and relevant configuration/runtime details; it does not change system settings or reboot the Deck. The installer does not reboot automatically.

## Benchmark results

Stock kernel baseline (2 samples):

| Metric | Stock kernel | New kernel (all features enabled) | Change |
|---|---:|---:|---:|
| Average | 65.66 | 68.36 | +4.11% |
| Minimum | 45.14 | 47.56 | +5.36% |
| Maximum | 90.10 | 90.91 | +0.90% |

The new-kernel figures are compared against the stock-kernel baseline. Percentage changes are calculated relative to the stock values.
