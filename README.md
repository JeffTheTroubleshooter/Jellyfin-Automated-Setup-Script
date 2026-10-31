# Jellyfin Automated Setup Script

`jellyfin-install.sh` builds [Jellyfin](https://jellyfin.org) from source with the official [jellyfin-packaging](https://github.com/jellyfin/jellyfin-packaging) tools, installs it to `/opt/jellyfin`, and sets it up as a systemd service that starts on boot.

## What it does

- Detects your Linux distro and installs the build dependencies, including Docker.
- Clones jellyfin-packaging and builds a portable Linux archive.
- Installs Jellyfin (default `/opt/jellyfin`) and creates a `jellyfin` systemd service.

## Install

```bash
bash jellyfin-install.sh
```

Then open `http://<your-server-ip>:8096` to finish Jellyfin's setup wizard.

Manage the service:

```bash
sudo systemctl status jellyfin
sudo systemctl restart jellyfin
```

## Uninstall

```bash
bash jellyfin-install.sh uninstall
```

This removes the service, the install files and the build folder, and asks before removing packages.
