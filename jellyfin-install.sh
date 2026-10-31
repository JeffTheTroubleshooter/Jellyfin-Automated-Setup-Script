#!/usr/bin/env bash
#
# Jellyfin installer / uninstaller (from source via jellyfin-packaging)
# Detects distro, installs build deps (including Docker), clones packaging repo,
# builds a portable Linux archive, installs it, and creates a systemd service.
#
# Usage:
#   bash jellyfin-install.sh            # install
#   bash jellyfin-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/jellyfin/jellyfin-packaging.git"
DEFAULT_DIR="/opt/jellyfin"
BUILD_DIR="/tmp/jellyfin-packaging"
SERVICE_NAME="jellyfin"
DEFAULT_PORT=8096

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Checking / installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git python3 python3-git python3-yaml docker.io curl ca-certificates
      ;;
    dnf)
      if ! command -v docker >/dev/null 2>&1; then
        sudo dnf install -y git python3 python3-GitPython python3-pyyaml docker curl ca-certificates || \
        sudo dnf install -y git python3 python3-GitPython python3-pyyaml moby-engine curl ca-certificates
      else
        sudo dnf install -y git python3 python3-GitPython python3-pyyaml curl ca-certificates
      fi
      ;;
    pacman)
      sudo pacman -Sy --noconfirm git python python-gitpython python-pyyaml docker curl ca-certificates
      ;;
    zypper)
      sudo zypper --non-interactive install git python3 python3-GitPython python3-PyYAML docker curl ca-certificates
      ;;
    apk)
      sudo apk add --no-cache git python3 py3-gitpython py3-yaml docker curl ca-certificates
      ;;
  esac

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    sudo rc-update add docker default 2>/dev/null || true
    sudo rc-service docker start 2>/dev/null || true
  fi

  ok "Dependencies ready."
}

# ── build ──────────────────────────────────────────────────────────────────
# Returns archive path via global ARCHIVE (avoids pipefail + command-sub issues)
build_jellyfin() {
  info "Cloning jellyfin-packaging..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  cd "$BUILD_DIR"

  info "Initializing submodules..."
  git submodule update --init

  info "Building portable Linux archive (this can take several minutes)..."
  if docker info >/dev/null 2>&1; then
    ./build.py auto linux amd64 || true
  else
    sudo ./build.py auto linux amd64 || true
  fi

  # Safe archive lookup (no pipefail issues)
  ARCHIVE=""
  local f
  for f in out/linux/jellyfin_*-amd64.tar.xz out/linux/jellyfin_*-amd64.tar.gz; do
    if [[ -f "$f" ]]; then
      ARCHIVE="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
      break
    fi
  done

  [[ -n "$ARCHIVE" ]] || die "Build finished but no archive found in out/linux/"
  info "Build complete: $ARCHIVE"
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  local archive="$1"
  info "Installing to $INSTALL_DIR ..."
  [[ -f "$archive" ]] || die "Archive not found: $archive"
  sudo mkdir -p "$INSTALL_DIR"
  sudo tar -xf "$archive" -C "$INSTALL_DIR" --strip-components=1
  sudo chown -R "$USER:$USER" "$INSTALL_DIR"
  ok "Files installed."
}

create_service() {
  local bin="$INSTALL_DIR/jellyfin"
  [[ -x "$bin" ]] || die "jellyfin binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=Jellyfin Media Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin --datadir $INSTALL_DIR/data --cachedir $INSTALL_DIR/cache --webdir $INSTALL_DIR/jellyfin-web
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."
  else
    warn "No systemd detected. Start manually with: $bin"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes media data/cache)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove build packages (git, python3, docker, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y git python3 python3-git python3-yaml docker.io || true ;;
      dnf)    sudo dnf remove -y git python3 python3-GitPython python3-pyyaml docker || true ;;
      pacman) sudo pacman -Rns --noconfirm git python python-gitpython python-pyyaml docker || true ;;
      zypper) sudo zypper --non-interactive remove git python3 python3-GitPython python3-PyYAML docker || true ;;
      apk)    sudo apk del git python3 py3-gitpython py3-yaml docker || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "Jellyfin uninstaller"
  echo "===================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Jellyfin installer (from source)"
      echo "================================"
      detect_distro
      install_packages

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"

      ARCHIVE=""
      build_jellyfin
      install_files "$ARCHIVE"
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:$DEFAULT_PORT"
      echo "  Files: $INSTALL_DIR"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
