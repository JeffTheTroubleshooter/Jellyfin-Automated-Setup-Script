# Jellyfin Automated Setup Script

`jellyfin-install.sh` builds [Jellyfin](https://jellyfin.org) from source with the official [jellyfin-packaging](https://github.com/jellyfin/jellyfin-packaging) tools, installs it to `/opt/jellyfin`, and sets it up as a systemd service that starts on boot.

## What it does

- Detects your Linux distro and installs the build dependencies (.NET SDK, Node.js, ffmpeg); no Docker.
- Clones jellyfin-packaging and builds a portable Linux archive.
- Installs Jellyfin (default `/opt/jellyfin`) and creates a `jellyfin` systemd service.

## Memory requirements and guard

Building from source (`dotnet publish` plus the webpack build of jellyfin-web) needs about **4 GB of RAM + swap**. Before building, the installer checks RAM, swap and the cgroup memory limit (so it sees an LXC's real limit) and stops with a clear message if there is too little. It also:

- sets `NODE_OPTIONS=--max-old-space-size` to about half of RAM (1–4 GB);
- runs `dotnet publish` with one build node (`-m:1`), no shared compiler server and workstation GC;
- runs each build step in its own process group and **stops at once** if the step exits with an error, if anything is OOM-killed in this machine's memory cgroup (`memory.events` `oom_kill`), or if a step runs longer than `STEP_TIMEOUT_SECS` (default 5400).

Overrides: `MIN_BUILD_MB=3072`, `JELLYFIN_ALLOW_LOW_MEM=1`, `STEP_TIMEOUT_SECS=0`. In a Proxmox LXC, raise memory with `pct set <ctid> --memory 4096 --swap 2048`.

For a Proxmox homelab, [Proxmox-Homelab-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Proxmox-Homelab-Automated-Setup-Script) runs Jellyfin from the official `jellyfin/jellyfin` Docker image instead of this source build.

## Supported distros

| Distro family | Status |
|---|---|
| Debian, Ubuntu, Linux Mint, Pop!_OS, Zorin, elementary OS | Expected to work |
| Fedora | Expected to work |
| Arch, Manjaro, EndeavourOS, Garuda | Not tested, need feedback |
| openSUSE, SLES | Not tested, need feedback |
| RHEL, Rocky, AlmaLinux, CentOS, Oracle Linux | Not tested, need feedback (Docker may need its own repo) |
| Alpine | Not tested, need feedback (no systemd service; start Jellyfin manually) |

If you try it on a distro marked "Not tested", please open an issue saying whether it worked.

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

## Part of the Proxmox Homelab setup

[Proxmox-Homelab-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Proxmox-Homelab-Automated-Setup-Script) sets up a full homelab on a Proxmox host. It now runs every app, Jellyfin included, from official Docker images and no longer uses this native installer.
