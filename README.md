# linux-saturnus-steamdeck

Compiler-optimized Steam Deck kernel based on Valve's SteamOS kernel and configuration, with the Van Gogh APU in mind.

LAVD scheduler is the only optional userspace addition.

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
