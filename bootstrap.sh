#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# bootstrap.sh
#
# Prepares a fresh Ubuntu Server for the home server stack.
#
# What it does:
#   1. Installs Docker (via official apt repository)
#   2. Installs Tailscale (via official apt repository) and starts interactive authentication
#   3. Installs Ansible (via pipx)
#   4. Clones the server repo to /opt/server
#
# Requirements:
#   - Ubuntu Server (tested on 24.04)
#   - Run with sudo: sudo ./bootstrap.sh
#   - A readonly GitHub PAT with access to caskey-server/server
#
# Idempotent: safe to re-run. Skips steps that are already complete.
# ==============================================================================

REPO_ORG="caskey-server"
REPO_NAME="server"
INSTALL_DIR="/opt/server"
TAILSCALE_SUBNET="192.168.1.0/24"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# ------------------------------------------------------------------------------
# Verify sudo
# ------------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    error "This script must be run as root (sudo ./bootstrap.sh)"
fi

SUDO_USER="${SUDO_USER:-}"
if [[ -z "${SUDO_USER}" ]]; then
    error "Run with sudo, not as a direct root login"
fi

# ------------------------------------------------------------------------------
# 1. Docker
# ------------------------------------------------------------------------------

if command_exists docker; then
    ok "Docker is already installed ($(docker --version))"
else
    info "Installing Docker..."

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    tee /etc/apt/sources.list.d/docker.sources <<EOF >/dev/null
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    ok "Docker installed ($(docker --version))"
fi

# ------------------------------------------------------------------------------
# 2. Tailscale
# ------------------------------------------------------------------------------

if command_exists tailscale; then
    ok "Tailscale is already installed"
else
    info "Installing Tailscale..."

    CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
        | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" \
        | tee /etc/apt/sources.list.d/tailscale.list >/dev/null

    apt-get update -qq
    apt-get install -y -qq tailscale

    ok "Tailscale installed"
fi

# Check connection status rather than just binary presence
if tailscale status &>/dev/null; then
    ok "Tailscale is already authenticated"
else
    info "Starting Tailscale interactive login..."
    tailscale up
    ok "Tailscale authenticated"
fi

# ------------------------------------------------------------------------------
# 3. Ansible
# ------------------------------------------------------------------------------

if sudo -u "${SUDO_USER}" bash -c 'command -v ansible &>/dev/null'; then
    ok "Ansible is already installed ($(sudo -u "${SUDO_USER}" ansible --version | head -1))"
else
    info "Installing Ansible via pipx..."

    # Ensure pipx is available
    if ! sudo -u "${SUDO_USER}" bash -c 'command -v pipx &>/dev/null'; then
        apt-get update -qq
        apt-get install -y -qq pipx
        sudo -u "${SUDO_USER}" pipx ensurepath
    fi

    sudo -u "${SUDO_USER}" pipx install --include-deps ansible
    ok "Ansible installed"
fi

# ------------------------------------------------------------------------------
# 4. Clone server repo
# ------------------------------------------------------------------------------

if [[ -d "${INSTALL_DIR}/.git" ]]; then
    ok "Server repo already cloned at ${INSTALL_DIR}"
else
    info "Cloning server repo to ${INSTALL_DIR}..."

    read -rsp "GitHub PAT (readonly): " GITHUB_PAT
    echo

    if [[ -z "${GITHUB_PAT}" ]]; then
        error "PAT cannot be empty"
    fi

    git clone --recurse-submodules \
        "https://${GITHUB_PAT}@github.com/${REPO_ORG}/${REPO_NAME}.git" \
        "${INSTALL_DIR}"

    # Set ownership to the invoking user so they can operate without sudo
    chown -R "${SUDO_USER}:${SUDO_USER}" "${INSTALL_DIR}"

    ok "Server repo cloned to ${INSTALL_DIR}"
fi

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------

echo ""
info "Bootstrap complete. Next steps:"
echo "  1. tailscale up --advertise-routes=${TAILSCALE_SUBNET} --accept-dns=false"
echo "  1. cd ${INSTALL_DIR}"
echo "  2. Run the Ansible playbook to deploy services"