# linux-saturnus-steamdeck

Compiler-optimized Steam Deck kernel based on Valve's SteamOS kernel and configuration, with the Van Gogh APU in mind.

## Installer behavior

The installer asks only whether to install/replace the kernel (default: yes). AMD P-State EPP boost is enabled automatically, and the LAVD scheduler is installed and enabled automatically in **Autopilot** mode. There are no separate EPP boost or LAVD prompts.

LAVD userspace is installed automatically. The selected scheduler configuration takes effect on the next boot. The installer does not reboot automatically.

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
