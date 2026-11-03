#!/usr/bin/env bash
#
# Jellyfin installer / uninstaller (from source via jellyfin-packaging)
# Memory guard: checks RAM/swap first, caps node/dotnet memory, and stops a
# build step at once if it dies, is OOM-killed, or runs past STEP_TIMEOUT_SECS.
# Detects distro, installs build deps (.NET SDK + Node.js), clones packaging repo,
# builds a portable Linux archive natively (no Docker), installs it, and creates a systemd service.
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
  local end
  end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
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
        git python3 python3-git python3-yaml python3-packaging curl ca-certificates tar gzip ffmpeg
      ;;
    dnf)    sudo dnf install -y git python3 python3-GitPython python3-pyyaml python3-packaging curl ca-certificates tar gzip ;;
    pacman) sudo pacman -Sy --noconfirm git python python-gitpython python-pyyaml python-packaging curl ca-certificates tar gzip ;;
    zypper) sudo zypper --non-interactive install git python3 python3-GitPython python3-PyYAML python3-packaging curl ca-certificates tar gzip ;;
    apk)    sudo apk add --no-cache git python3 py3-gitpython py3-yaml py3-packaging curl ca-certificates tar gzip ;;
  esac

  ok "Dependencies ready."
}

# ── python modules needed by jellyfin-packaging/build.py ───────────────────
# build.py imports: git (GitPython), yaml (PyYAML), packaging. Install via the
# distro packages above; fall back to pip (--break-system-packages) for any
# module still missing, then fail clearly if one can't be imported.
PY_MODS=(git yaml packaging)
py_mod_pip_name() {
  case "$1" in
    git) echo GitPython ;; yaml) echo PyYAML ;; *) echo "$1" ;;
  esac
}
missing_py_mods() {
  local m out=()
  for m in "${PY_MODS[@]}"; do
    python3 -c "import $m" >/dev/null 2>&1 || out+=("$m")
  done
  echo "${out[*]:-}"
}
ensure_python_modules() {
  command -v python3 >/dev/null 2>&1 || die "python3 not found after installing dependencies."
  local missing m pips=()
  missing=$(missing_py_mods)
  [[ -z "$missing" ]] && { ok "Python modules ready (${PY_MODS[*]})."; return 0; }
  warn "Python modules missing from distro packages: $missing — trying pip..."
  for m in $missing; do pips+=("$(py_mod_pip_name "$m")"); done
  if ! python3 -m pip --version >/dev/null 2>&1; then
    case "$PKG" in
      apt)    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip || true ;;
      dnf)    sudo dnf install -y python3-pip || true ;;
      pacman) sudo pacman -S --noconfirm python-pip || true ;;
      zypper) sudo zypper --non-interactive install python3-pip || true ;;
      apk)    sudo apk add --no-cache py3-pip || true ;;
    esac
  fi
  sudo python3 -m pip install --break-system-packages "${pips[@]}" 2>/dev/null || \
    sudo python3 -m pip install "${pips[@]}" || true
  missing=$(missing_py_mods)
  [[ -z "$missing" ]] || die "Python module(s) still missing: $missing. build.py needs: GitPython, PyYAML, packaging. Install them and rerun."
  ok "Python modules ready (${PY_MODS[*]})."
}

# ── build ──────────────────────────────────────────────────────────────────
# Native from-source build (no Docker). jellyfin-packaging's build.py runs
# `docker buildx build` via os.system() and ignores its exit code; Debian's
# docker.io has no buildx plugin and CT 201 is an unprivileged LXC without
# keyctl, so the image is never built and the failure only shows up later as
# "pull access denied". Instead we do exactly what portable/build.sh does in
# that image (dotnet publish + npm run build:production), directly on the host,
# with the same .NET / Node versions build.yaml pins for the submodule HEADs.
BUILD_LOG="/var/log/jellyfin-build.log"

# Print "KEY=VALUE" for DOTNET_VERSION / NODEJS_VERSION, mirroring build.py's
# _determine_framework_versions (newest pinned commit that is an ancestor of HEAD).
framework_versions() {
  python3 - <<'PY'
import subprocess, yaml
from packaging.version import Version
cfg = yaml.safe_load(open("build.yaml"))["frameworks"]
for sub, args in cfg.items():
    for key, pins in args.items():
        val = None
        for commit, v in sorted(pins.items(), key=lambda kv: Version(str(kv[1]))):
            if subprocess.run(["git", "-C", sub, "merge-base", "--is-ancestor", commit, "HEAD"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                val = v
        if val is not None:
            print(f"{key}={val}")
PY
}

# ver_ge A B: true if version A >= version B
ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }

# jellyfin-web's package.json pins engines.npm (10.11: ">=9.6.4"). Debian 13's
# own Node 20 is fine, but its npm is 9.2.0, so `npm ci` stops with EBADENGINE.
# Upgrade npm in place to a pinned major that supports Node 20 when it is too old.
NPM_PIN="${NPM_PIN:-10}"
ensure_npm_engine() {
  local need cur
  need=$(python3 -c 'import json,re; e=json.load(open("jellyfin-web/package.json")).get("engines",{}).get("npm",""); m=re.search(r"[0-9]+(\.[0-9]+)*", e); print(m.group(0) if m else "")' 2>/dev/null || true)
  [[ -n "$need" ]] || return 0
  cur=$(npm -v 2>/dev/null || echo 0)
  ver_ge "$cur" "$need" && return 0
  info "npm $cur is older than $need (jellyfin-web engines); installing npm@${NPM_PIN}..."
  sudo npm install -g "npm@${NPM_PIN}" || die "npm install -g npm@${NPM_PIN} failed."
  hash -r
  cur=$(npm -v 2>/dev/null || echo 0)
  ver_ge "$cur" "$need" || die "npm is $cur after upgrading; jellyfin-web needs npm >= $need."
  ok "npm $cur (jellyfin-web needs >= $need)"
}

install_toolchain() {
  local dotnet_ver="$1" node_ver="$2"
  [[ "$PKG" == "apt" ]] || die "Native Jellyfin build supports Debian/Ubuntu only (detected $ID). Install dotnet-sdk-$dotnet_ver and Node.js $node_ver manually, then rerun."
  # shellcheck disable=SC1091
  . /etc/os-release
  local msid="$ID" msver="$VERSION_ID"
  [[ "$msid" == "debian" ]] && msver="${VERSION_ID%%.*}"
  if ! dotnet --list-sdks 2>/dev/null | grep -q "^${dotnet_ver}\."; then
    info "Installing .NET SDK $dotnet_ver (packages.microsoft.com)..."
    curl -fsSL "https://packages.microsoft.com/config/${msid}/${msver}/packages-microsoft-prod.deb" -o /tmp/packages-microsoft-prod.deb \
      || die "Could not download Microsoft repo config for ${msid} ${msver}."
    sudo dpkg -i /tmp/packages-microsoft-prod.deb
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "dotnet-sdk-${dotnet_ver}" \
      || die "apt could not install dotnet-sdk-${dotnet_ver}."
  fi
  if [[ "$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')" != "$node_ver" ]]; then
    info "Installing Node.js $node_ver (NodeSource)..."
    curl -fsSL "https://deb.nodesource.com/setup_${node_ver}.x" -o /tmp/nodesource-setup.sh \
      || die "Could not download NodeSource setup for Node.js $node_ver."
    sudo bash /tmp/nodesource-setup.sh
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs || die "apt could not install nodejs $node_ver."
  fi
  ensure_npm_engine
  ok "Toolchain: .NET $(dotnet --version), Node $(node -v), npm $(npm -v)"
}

# ── memory guard ───────────────────────────────────────────────────────────
# The source build (dotnet publish + webpack) needs real memory. In a small
# LXC/VM the kernel OOM-kills dotnet and the web build can then stall for
# hours. Check RAM/swap up front, cap node/dotnet memory, and stop as soon as
# a build step dies or anything in this machine's memory cgroup is OOM-killed.
MIN_BUILD_MB="${MIN_BUILD_MB:-4096}"          # RAM + swap needed for the build
STEP_TIMEOUT_SECS="${STEP_TIMEOUT_SECS:-5400}" # per build step; 0 = no limit
MEM_MB=0 SWAP_MB=0

# Usable memory: the smaller of /proc/meminfo (lxcfs shows the CT limit there)
# and the cgroup v2/v1 limit, if one is set.
detect_memory() {
  local lim
  MEM_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
  SWAP_MB=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
  lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo max)
  if [[ "$lim" =~ ^[0-9]+$ ]] && (( lim / 1048576 < MEM_MB )); then
    MEM_MB=$(( lim / 1048576 ))
  fi
}

check_memory() {
  detect_memory
  local avail total=$(( MEM_MB + SWAP_MB ))
  avail=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
  info "Memory: ${MEM_MB} MB RAM (${avail} MB available), ${SWAP_MB} MB swap; build needs >= ${MIN_BUILD_MB} MB RAM+swap."
  if (( total < MIN_BUILD_MB )); then
    if [[ "${JELLYFIN_ALLOW_LOW_MEM:-0}" == "1" ]]; then
      warn "Only ${total} MB RAM+swap; continuing because JELLYFIN_ALLOW_LOW_MEM=1."
    else
      die "Only ${total} MB RAM+swap (need ${MIN_BUILD_MB} MB to build Jellyfin from source).
  Give this machine more memory or swap (Proxmox LXC: pct set <ctid> --memory 4096 --swap 2048),
  or set JELLYFIN_ALLOW_LOW_MEM=1 / MIN_BUILD_MB=<n> to try anyway."
    fi
  fi
  # node heap: ~half of RAM, between 1024 and 4096 MB
  local heap=$(( MEM_MB / 2 ))
  (( heap < 1024 )) && heap=1024
  (( heap > 4096 )) && heap=4096
  export NODE_OPTIONS="--max-old-space-size=${heap}"
  # dotnet: workstation GC, conserve memory, no long-lived compiler server
  export DOTNET_gcServer=0 DOTNET_GCConserveMemory=7 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
  export MSBUILDDISABLENODEREUSE=1 DOTNET_CLI_USE_MSBUILD_SERVER=0
  info "Limits: NODE_OPTIONS=$NODE_OPTIONS, dotnet single-node build (-m:1), workstation GC."
}

# OOM kills charged to this machine's memory cgroup so far.
oom_kills() {
  local n
  n=$(awk '/^oom_kill / {print $2}' /sys/fs/cgroup/memory.events 2>/dev/null || true)
  [[ -n "$n" ]] || n=$(awk '/^oom_kill / {print $2}' /sys/fs/cgroup/memory/memory.oom_control 2>/dev/null || true)
  echo "${n:-0}"
}

# run_step <label> <cmd...>: run a build step in its own process group with
# output in $BUILD_LOG. Fails fast (kills the whole step) on an OOM kill, on
# timeout, or when the step exits non-zero; prints a progress line every 60s.
run_step() {
  local label="$1" pid rc=0 t0 now oom0 last=0
  shift
  oom0=$(oom_kills)
  t0=$(date +%s)
  setsid "$@" >>"$BUILD_LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    now=$(date +%s)
    if (( $(oom_kills) > oom0 )); then
      kill -KILL -- "-$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
      tail -n 20 "$BUILD_LOG" >&2
      die "$label: the kernel OOM-killed a build process (out of memory). Give this machine more RAM/swap (need >= ${MIN_BUILD_MB} MB) and rerun. See $BUILD_LOG"
    fi
    if (( STEP_TIMEOUT_SECS > 0 && now - t0 >= STEP_TIMEOUT_SECS )); then
      kill -TERM -- "-$pid" 2>/dev/null || true; sleep 3; kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      tail -n 20 "$BUILD_LOG" >&2
      die "$label did not finish within $(( STEP_TIMEOUT_SECS / 60 ))m (STEP_TIMEOUT_SECS). See $BUILD_LOG"
    fi
    if (( now - last >= 60 )); then
      last=$now
      info "  ... $label: $(( (now - t0) / 60 ))m $(( (now - t0) % 60 ))s"
    fi
  done
  wait "$pid" || rc=$?
  if (( rc != 0 )); then
    tail -n 40 "$BUILD_LOG" >&2
    if (( rc == 137 )) || (( $(oom_kills) > oom0 )); then
      die "$label was killed (exit $rc, likely out of memory). Give this machine more RAM/swap and rerun. See $BUILD_LOG"
    fi
    die "$label failed (exit $rc). See $BUILD_LOG"
  fi
}

# Returns archive path via global ARCHIVE
build_jellyfin() {
  info "Cloning jellyfin-packaging..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  cd "$BUILD_DIR"

  info "Initializing submodules (jellyfin-server, jellyfin-web)..."
  git submodule update --init jellyfin-server jellyfin-web

  ensure_python_modules
  local DOTNET_VERSION=8.0 NODEJS_VERSION=20 kv
  while IFS= read -r kv; do
    case "$kv" in
      DOTNET_VERSION=*) DOTNET_VERSION="${kv#*=}" ;;
      NODEJS_VERSION=*) NODEJS_VERSION="${kv#*=}" ;;
    esac
  done < <(framework_versions)
  info "Framework versions from build.yaml: .NET $DOTNET_VERSION, Node $NODEJS_VERSION"
  install_toolchain "$DOTNET_VERSION" "$NODEJS_VERSION"

  local stage="$BUILD_DIR/stage/jellyfin" version
  version="$(date +%Y%m%d%H)"
  rm -rf "$BUILD_DIR/stage" && mkdir -p "$stage" "$BUILD_DIR/out/linux"
  sudo touch "$BUILD_LOG" && sudo chown "$USER" "$BUILD_LOG" && : > "$BUILD_LOG"
  info "Building Jellyfin from source (several minutes; full log: $BUILD_LOG)..."

  info "[1/3] dotnet publish jellyfin-server..."
  run_step "dotnet publish (jellyfin-server)" bash -c "cd jellyfin-server && dotnet publish Jellyfin.Server --configuration Release \
      --self-contained --runtime linux-x64 --output '$stage' -m:1 \
      -p:UseSharedCompilation=false -p:DebugSymbols=false -p:DebugType=none -p:UseAppHost=true"
  dotnet build-server shutdown >/dev/null 2>&1 || true

  info "[2/3] npm ci + build jellyfin-web..."
  run_step "jellyfin-web build" bash -c "cd jellyfin-web && npm ci --no-audit --unsafe-perm && npm run build:production \
      && rm -rf '$stage/jellyfin-web' && mv dist '$stage/jellyfin-web'"

  info "[3/3] Packing archive..."
  ARCHIVE="$BUILD_DIR/out/linux/jellyfin_${version}-amd64.tar.gz"
  tar -C "$BUILD_DIR/stage" -czf "$ARCHIVE" jellyfin/ || die "Could not create $ARCHIVE"
  [[ -x "$stage/jellyfin" && -f "$stage/jellyfin-web/index.html" ]] \
    || die "Build produced an incomplete tree (missing jellyfin binary or web UI). See $BUILD_LOG"
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
Restart=always
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
  if ask_yn "Also remove build packages (git, python3, dotnet, nodejs, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y git python3 python3-git python3-yaml python3-packaging dotnet-sdk-* nodejs || true ;;
      dnf)    sudo dnf remove -y git python3 python3-GitPython python3-pyyaml python3-packaging || true ;;
      pacman) sudo pacman -Rns --noconfirm git python python-gitpython python-pyyaml python-packaging || true ;;
      zypper) sudo zypper --non-interactive remove git python3 python3-GitPython python3-PyYAML python3-packaging || true ;;
      apk)    sudo apk del git python3 py3-gitpython py3-yaml py3-packaging || true ;;
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
      check_memory

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
