#!/usr/bin/env bash
set -euo pipefail
# Public-safe bootstrap for a fresh Raspberry Pi (or Debian-based host).
# - No hardcoded username/paths/URLs.
# - Parameterized via environment variables; sane defaults.
# - Idempotent: safe to re-run.
#
# Example (with placeholders replaced):
#   sudo USERNAME=pi REPO_URL=https://github.com/yourorg/homeauto-stack-starter VIC_GIT_URL=https://github.com/yourorg/victron-ble2mqtt-fork ./scripts/bootstrap.sh

### ========= USER/ENV VARS =========
USERNAME="${USERNAME:-${SUDO_USER:-pi}}"
HOME_DIR="/home/${USERNAME}"

# Repo containing stack/configs (public)
REPO_URL="${REPO_URL:-https://github.com/YOURORG/homeauto-stack-starter}"
REPO_DIR="${REPO_DIR:-${HOME_DIR}/repos/homeauto-stack-starter}"
BRANCH="${BRANCH:-main}"

# On-host data root used by the stack
SRC_ROOT="${SRC_ROOT:-/srv/home-automation}"

# Victron BLE project (public fork or upstream)
VIC_PROJECT_DIR="${VIC_PROJECT_DIR:-${HOME_DIR}/victron-ble2mqtt}"
VIC_GIT_URL="${VIC_GIT_URL:-https://github.com/YOURORG/victron-ble2mqtt-fork}"

# Python venv used by systemd unit
VENV_DIR="${VENV_DIR:-${HOME_DIR}/victron-venv}"

# Systemd unit path
UNIT_PATH="/etc/systemd/system/victron_ble2mqtt.service"

### ========= FUNCTIONS =========
log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Please run with sudo:  sudo ${0}"
    exit 1
  fi
}

ensure_user_dirs() {
  mkdir -p "${HOME_DIR}"/{repos,bin}
  chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}/repos" "${HOME_DIR}/bin"
}

apt_install() {
  log "Updating apt and installing base packages…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    git curl ca-certificates gnupg lsb-release \
    python3 python3-venv python3-pip \
    bluetooth bluez libbluetooth-dev libglib2.0-dev pkg-config
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine via apt…"
    apt-get install -y docker.io docker-compose-plugin
    systemctl enable --now docker
  else
    log "Docker already installed."
  fi
  if ! id -nG "${USERNAME}" | grep -q '\bdocker\b'; then
    usermod -aG docker "${USERNAME}" || true
    log "User ${USERNAME} added to docker group (log out/in to take effect)."
  fi
}

ensure_swarm() {
  if ! docker info 2>/dev/null | grep -Eiq '^ *Swarm: +active'; then
    log "Initializing Docker Swarm…"
    docker swarm init || true
  else
    log "Docker Swarm already active."
  fi
}

prepare_src_root() {
  log "Preparing ${SRC_ROOT} structure…"
  mkdir -p "${SRC_ROOT}"/{mosquitto/config,homeassistant,node-red}
  chown -R "${USERNAME}:${USERNAME}" "${SRC_ROOT}"
  if [ ! -f "${SRC_ROOT}/mosquitto/config/mosquitto.conf" ]; then
    cat > "${SRC_ROOT}/mosquitto/config/mosquitto.conf" <<MOSQ
persistence true
persistence_location /mosquitto/data/
log_dest stdout
log_timestamp true
listener 1883 0.0.0.0
allow_anonymous true
MOSQ
    chown "${USERNAME}:${USERNAME}" "${SRC_ROOT}/mosquitto/config/mosquitto.conf"
  fi
}

sync_repo_stack() {
  log "Ensuring stack repo present at ${REPO_DIR}…"
  if [ -d "${REPO_DIR}/.git" ]; then
    su - "${USERNAME}" -c "cd '${REPO_DIR}' && git fetch --all && git checkout '${BRANCH}' && git pull --ff-only"
  else
    su - "${USERNAME}" -c "git clone --branch '${BRANCH}' '${REPO_URL}' '${REPO_DIR}'"
  fi
}

deploy_stack() {
  log "Deploying Swarm stack…"
  su - "${USERNAME}" -c "cd '${REPO_DIR}' && docker stack deploy -c stack/home-automation.stack.yml homeauto"
  docker stack services homeauto || true
}

setup_victron_project() {
  log "Ensuring victron project at ${VIC_PROJECT_DIR}…"
  if [ ! -d "${VIC_PROJECT_DIR}" ]; then
    if [ -n "${VIC_GIT_URL}" ]; then
      su - "${USERNAME}" -c "git clone '${VIC_GIT_URL}' '${VIC_PROJECT_DIR}'"
    else
      log "VIC_GIT_URL not set and ${VIC_PROJECT_DIR} not found. Skipping clone."
    fi
  else
    log "Found existing victron project dir."
    if [ -d "${VIC_PROJECT_DIR}/.git" ]; then
      su - "${USERNAME}" -c "cd '${VIC_PROJECT_DIR}' && git pull --ff-only || true"
    fi
  fi
}

setup_python_env() {
  log "Creating/updating Python venv at ${VENV_DIR}…"
  su - "${USERNAME}" -c "python3 -m venv '${VENV_DIR}'"
  su - "${USERNAME}" -c "'${VENV_DIR}/bin/pip' install --upgrade pip wheel setuptools"
  if [ -d "${VIC_PROJECT_DIR}" ]; then
    if [ -f "${VIC_PROJECT_DIR}/pyproject.toml" ] || [ -f "${VIC_PROJECT_DIR}/setup.py" ]; then
      su - "${USERNAME}" -c "'${VENV_DIR}/bin/pip' install -U '${VIC_PROJECT_DIR}'"
    fi
    su - "${USERNAME}" -c "'${VENV_DIR}/bin/pip' install -U bleak"
  fi
}

install_systemd_unit() {
  log "Installing systemd unit to ${UNIT_PATH}…"
  cat > "${UNIT_PATH}" <<UNIT
[Unit]
Description=victron_ble2mqtt (Python launcher)
After=network-online.target bluetooth.service mosquitto.service
Wants=network-online.target bluetooth.service

[Service]
Type=simple
User=${USERNAME}
Group=${USERNAME}
WorkingDirectory=${VIC_PROJECT_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_DIR}/bin/python3 ${VIC_PROJECT_DIR}/custom/run_victron_python.py
Restart=always
RestartSec=5
SyslogIdentifier=victron_ble2mqtt

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable victron_ble2mqtt.service
  if [ -x "${VENV_DIR}/bin/python3" ] && [ -f "${VIC_PROJECT_DIR}/custom/run_victron_python.py" ]; then
    systemctl restart victron_ble2mqtt.service || systemctl start victron_ble2mqtt.service || true
  else
    log "Victron project not ready yet; service will start after project is in place."
  fi
}

summary() {
  log "Bootstrap complete."
  echo "Check services:"
  echo "  docker stack services homeauto"
  echo "  systemctl status victron_ble2mqtt.service"
  echo
  echo "Override defaults via env vars when running this script."
  echo "Examples:"
  echo "  sudo USERNAME=pi REPO_URL=https://github.com/YOURORG/homeauto-stack-starter \\"
  echo "       VIC_GIT_URL=https://github.com/YOURORG/victron-ble2mqtt-fork \\"
  echo "       ${REPO_DIR}/scripts/bootstrap.sh"
}

### ========= MAIN =========
require_root
ensure_user_dirs
apt_install
install_docker
ensure_swarm
prepare_src_root
sync_repo_stack
deploy_stack
setup_victron_project
setup_python_env
install_systemd_unit
summary
