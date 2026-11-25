# linux-saturnus-steamdeck

Compiler-optimized Steam Deck kernel based on Valve's SteamOS kernel and configuration, with the Van Gogh APU in mind.

## Installer choices

The installer presents these as separate choices; selecting one does not automatically determine any of the others:

- **Install/replace the kernel?** (default: yes). You can decline kernel replacement and continue with the other installer options.
- **Disable AMD P-State EPP boost?** (default: no). EPP boost therefore remains enabled by default.
- **Enable the LAVD scheduler?** (asked at the end; default: yes). If enabled, choose **Performance** or **Autopilot** mode. Autopilot is the existing default mode.

LAVD userspace is installed automatically as part of the LAVD setup. The selected scheduler mode is written to its configuration and takes effect on the next boot. The installer does not reboot automatically.

## Benchmarks

Each configuration was tested twice. The table shows both samples, their arithmetic mean, and the percentage difference from the stock-kernel mean for each test. Test names and measurement units were not provided, so the results are labelled Test 1–3. Percentages compare the measured values; they do not by themselves establish that a higher value is better.

| Configuration | Test 1 (samples) | Mean | vs. stock | Test 2 (samples) | Mean | vs. stock | Test 3 (samples) | Mean | vs. stock |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Stock kernel** | 65.66 / 64.53 | 65.10 | — | 45.14 / 44.50 | 44.82 | — | 90.10 / 89.52 | 89.81 | — |
| New kernel, EPP/LAVD off | 67.14 / 66.24 | 66.69 | +2.45% | 45.08 / 45.18 | 45.13 | +0.69% | 91.54 / 90.89 | 91.22 | +1.56% |
| New kernel + EPP boost | 68.01 / 67.17 | 67.59 | +3.83% | 45.23 / 45.19 | 45.21 | +0.87% | 91.99 / 91.52 | 91.76 | +2.17% |
| New kernel + EPP boost + LAVD Autopilot | 69.70 / 68.67 | 69.19 | +6.28% | 46.73 / 47.44 | 47.09 | +5.05% | 92.11 / 90.93 | 91.52 | +1.90% |
| New kernel + EPP boost + LAVD Performance | 68.90 / 68.00 | 68.45 | +5.15% | 45.96 / 46.80 | 46.38 | +3.48% | 90.89 / 90.56 | 90.73 | +1.02% |

*Percentage difference is calculated from the two-sample mean for each configuration relative to the corresponding stock-kernel mean.*

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
