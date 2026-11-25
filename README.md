# linux-saturnus-steamdeck

Compiler-optimized Steam Deck kernel based on Valve's SteamOS kernel and configuration, with the Van Gogh APU in mind.

## Installer choices

The installer presents these as separate choices; selecting one does not automatically determine any of the others:

- **Install/replace the kernel?** (default: yes). You can decline kernel replacement and continue with the other installer options.
- **Disable AMD P-State EPP boost?** (default: no). EPP boost therefore remains enabled by default.
- **Enable the LAVD scheduler?** (asked at the end; default: yes). If enabled, choose **Performance** or **Autopilot** mode. Autopilot is the existing default mode.

LAVD userspace is installed automatically as part of the LAVD setup. The selected scheduler mode is written to its configuration and takes effect on the next boot. The installer does not reboot automatically.

## Benchmarks

Each configuration was tested twice. For each test, the table reports the two samples, their average, minimum and maximum, plus the percentage difference for each statistic against the corresponding stock-kernel result. Test names and measurement units were not provided, so they are labelled Test 1–3.

| Configuration | Test | Samples | Average (Δ) | Minimum (Δ) | Maximum (Δ) |
|---|---:|---:|---:|---:|---:|
| Stock kernel | 1 | 65.66 / 64.53 | 65.10 (—) | 64.53 (—) | 65.66 (—) |
| Stock kernel | 2 | 45.14 / 44.50 | 44.82 (—) | 44.50 (—) | 45.14 (—) |
| Stock kernel | 3 | 90.10 / 89.52 | 89.81 (—) | 89.52 (—) | 90.10 (—) |
| New kernel, EPP/LAVD off | 1 | 67.14 / 66.24 | 66.69 (+2.45%) | 66.24 (+2.65%) | 67.14 (+2.25%) |
| New kernel, EPP/LAVD off | 2 | 45.08 / 45.18 | 45.13 (+0.69%) | 45.08 (+1.30%) | 45.18 (+0.09%) |
| New kernel, EPP/LAVD off | 3 | 91.54 / 90.89 | 91.22 (+1.56%) | 90.89 (+1.53%) | 91.54 (+1.60%) |
| New kernel + EPP boost | 1 | 68.01 / 67.17 | 67.59 (+3.83%) | 67.17 (+4.09%) | 68.01 (+3.58%) |
| New kernel + EPP boost | 2 | 45.23 / 45.19 | 45.21 (+0.87%) | 45.19 (+1.55%) | 45.23 (+0.20%) |
| New kernel + EPP boost | 3 | 91.99 / 91.52 | 91.76 (+2.17%) | 91.52 (+2.23%) | 91.99 (+2.10%) |
| New kernel + EPP boost + LAVD Autopilot | 1 | 69.70 / 68.67 | 69.19 (+6.28%) | 68.67 (+6.42%) | 69.70 (+6.15%) |
| New kernel + EPP boost + LAVD Autopilot | 2 | 46.73 / 47.44 | 47.09 (+5.05%) | 46.73 (+5.01%) | 47.44 (+5.10%) |
| New kernel + EPP boost + LAVD Autopilot | 3 | 92.11 / 90.93 | 91.52 (+1.90%) | 90.93 (+1.58%) | 92.11 (+2.23%) |
| New kernel + EPP boost + LAVD Performance | 1 | 68.90 / 68.00 | 68.45 (+5.15%) | 68.00 (+5.38%) | 68.90 (+4.93%) |
| New kernel + EPP boost + LAVD Performance | 2 | 45.96 / 46.80 | 46.38 (+3.48%) | 45.96 (+3.28%) | 46.80 (+3.68%) |
| New kernel + EPP boost + LAVD Performance | 3 | 90.89 / 90.56 | 90.73 (+1.02%) | 90.56 (+1.16%) | 90.89 (+0.88%) |

### Overall percentage difference vs. stock

Overall percentages are the arithmetic mean of the percentage differences across Tests 1–3. This gives each test equal weight rather than combining raw values from tests that may use different scales.

| Configuration | Average Δ | Minimum Δ | Maximum Δ |
|---|---:|---:|---:|
| Stock kernel | — | — | — |
| New kernel, EPP/LAVD off | +1.57% | +1.83% | +1.31% |
| New kernel + EPP boost | +2.29% | +2.63% | +1.96% |
| New kernel + EPP boost + LAVD Autopilot | +4.41% | +4.33% | +4.49% |
| New kernel + EPP boost + LAVD Performance | +3.22% | +3.27% | +3.16% |

*Δ is the percentage difference from the stock-kernel result for the same test and statistic. Positive values indicate a higher measured value; whether that is better depends on what each test measures.*


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
