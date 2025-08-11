HomeAuto Stack Starter
Generic Docker Swarm stack + Victron BLE to MQTT service bootstrap for Raspberry Pi or other Debian-based hosts.

This repo contains:

A scripts/bootstrap.sh installer that sets up:

Docker & Docker Swarm

Mosquitto MQTT broker

Home Assistant

Node-RED

Victron BLE → MQTT service (systemd)

No hardcoded usernames or private paths.

All configuration is parameterized through environment variables.

Quick Start
bash
Copy
Edit
# Clone this repo or download bootstrap.sh
# Run as root (sudo) with your desired variables:
sudo USERNAME=pi \
     REPO_URL=https://github.com/YOURUSER/homeauto-stack-starter \
     VIC_GIT_URL=https://github.com/YOURUSER/victron-ble2mqtt-fork \
     ./scripts/bootstrap.sh
Defaults:

USERNAME → detected from SUDO_USER or "pi"

REPO_URL → this repo

BRANCH → main

SRC_ROOT → /srv/home-automation

VIC_PROJECT_DIR → /home/<user>/victron-ble2mqtt

VENV_DIR → /home/<user>/victron-venv
