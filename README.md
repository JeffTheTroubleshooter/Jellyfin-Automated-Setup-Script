# Jellyfin Automated Setup Script

`jellyfin-install.sh` builds [Jellyfin](https://jellyfin.org) from source with the official [jellyfin-packaging](https://github.com/jellyfin/jellyfin-packaging) tools, installs it to `/opt/jellyfin`, and sets it up as a systemd service that starts on boot.

## What it does

- Detects your Linux distro and installs the build dependencies (.NET SDK, Node.js, ffmpeg); no Docker.
- If the distro archive and the Microsoft apt repo do not carry the required .NET SDK (for example on Ubuntu 26.04), the installer falls back to Microsoft's official `dotnet-install.sh`.
- Clones jellyfin-packaging and builds a portable Linux archive under `/var/tmp` (not `/tmp`, which is often a small tmpfs).
- Checks that the install and build disks have at least 2 GB free before building.
- Installs Jellyfin (default `/opt/jellyfin`) and creates a `jellyfin` systemd service with `TMPDIR=/opt/jellyfin/temp`, so startup does not crash when `/tmp` is too small.
- After starting the service, waits up to 30 seconds for port 8096 to respond. If it does not, the script prints the last journal lines and exits with an error instead of printing "Done".
- Rerunning the installer is safe: it stops an existing service, overwrites the files, rewrites the unit, and reloads systemd. Media data and cache are kept.
- After the service starts, offers to create media library folders under `/mnt` for Jellyfin's content types (Movies, Music, Shows, Books, Home Videos and Photos, Music Videos, Mixed Movies and Shows). You can pick several, choose all, or skip. Folders are owned by the Jellyfin service user, mode `775`, with access for the user who ran the script (`SUDO_USER`) so you can copy files in. Then add each folder in Jellyfin under **Dashboard > Libraries > Add Media Library**.

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

After the service starts, the installer asks which media folders to create under `/mnt` (for example `/mnt/Movies`, `/mnt/Shows`). Type numbers such as `1 3 5`, `a` for all, or press Enter / `s` to skip. To skip the prompt:

```bash
bash jellyfin-install.sh --media-folders=all
bash jellyfin-install.sh --media-folders=movies,shows
bash jellyfin-install.sh --media-folders=none
```

If stdin is not a terminal and you did not pass `--media-folders`, folder creation is skipped. To create folders later without rebuilding Jellyfin:

```bash
bash jellyfin-install.sh folders
bash jellyfin-install.sh folders --media-folders=all
```

Then open `http://<your-server-ip>:8096` to finish Jellyfin's setup wizard, and add each folder under **Dashboard > Libraries > Add Media Library** with the matching content type.

Manage the service:

```bash
sudo systemctl status jellyfin
sudo systemctl restart jellyfin
```

## Uninstall

```bash
bash jellyfin-install.sh uninstall
```

This removes the service (including any systemd drop-ins), `/opt/jellyfin/temp`, the install files and the build folder, and asks before removing packages. It does **not** delete media folders under `/mnt` (they may hold your files); the uninstaller only lists them if they exist.

## Part of the Proxmox Homelab setup

[Proxmox-Homelab-Automated-Setup-Script](https://github.com/JeffTheTroubleshooter/Proxmox-Homelab-Automated-Setup-Script) sets up a full homelab on a Proxmox host. It now runs every app, Jellyfin included, from official Docker images and no longer uses this native installer.
