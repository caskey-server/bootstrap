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

REAL_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)

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
# 3. Kernel networking configuration (for Tailscale subnet routes)
# ------------------------------------------------------------------------------

# IPv6 forwarding (required for Tailscale subnet routes)
if grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    ok "IPv6 forwarding already enabled"
else
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    ok "IPv6 forwarding enabled"
fi

# UDP GRO forwarding (performance optimisation for Tailscale)
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [[ -z "${DEFAULT_IFACE}" ]]; then
    warn "Could not detect default network interface — skipping UDP GRO configuration"
else
    ETHTOOL_SERVICE="/etc/systemd/system/ethtool-udp-gro.service"
    if [[ -f "${ETHTOOL_SERVICE}" ]]; then
        ok "UDP GRO service already configured"
    else
        apt-get install -y -qq ethtool
        cat > "${ETHTOOL_SERVICE}" <<EOF
[Unit]
Description=Configure UDP GRO forwarding for Tailscale
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -K ${DEFAULT_IFACE} rx-udp-gro-forwarding on rx-gro-list off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now ethtool-udp-gro.service
        ok "UDP GRO forwarding configured on ${DEFAULT_IFACE}"
    fi
fi

# ------------------------------------------------------------------------------
# 4. Ansible
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
# 5. Clone server repo
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

    # Store the PAT in the credential store so Git doesn't prompt
    sudo -u "${SUDO_USER}" HOME="${REAL_HOME}" git config --global credential.helper store
    sudo -u "${SUDO_USER}" bash -c "echo 'https://git:${GITHUB_PAT}@github.com' > '${REAL_HOME}/.git-credentials'"
    chmod 0600 "${REAL_HOME}/.git-credentials"
    chown "${SUDO_USER}:${SUDO_USER}" "${REAL_HOME}/.git-credentials"

    mkdir -p "${INSTALL_DIR}"
    chown "${SUDO_USER}:${SUDO_USER}" "${INSTALL_DIR}"

    sudo -u "${SUDO_USER}" HOME="${REAL_HOME}" git clone --recurse-submodules \
        "https://github.com/${REPO_ORG}/${REPO_NAME}.git" \
        "${INSTALL_DIR}"

    chown -R "${SUDO_USER}:${SUDO_USER}" "${INSTALL_DIR}"

    ok "Server repo cloned to ${INSTALL_DIR}"
fi

# ------------------------------------------------------------------------------
# 6. Ansible vault password
# ------------------------------------------------------------------------------

VAULT_PASS_FILE="${REAL_HOME}/.vault_pass"

if [[ -f "${VAULT_PASS_FILE}" ]]; then
    ok "Ansible vault password file already exists"
else
    info "Setting up Ansible vault password..."

    read -rsp "Ansible vault password: " vault_pass
    echo

    if [[ -z "${vault_pass}" ]]; then
        error "Vault password cannot be empty"
    fi

    echo "${vault_pass}" > "${VAULT_PASS_FILE}"
    chmod 0600 "${VAULT_PASS_FILE}"
    chown "${SUDO_USER}:${SUDO_USER}" "${VAULT_PASS_FILE}"

    ok "Vault password saved to ${VAULT_PASS_FILE}"
fi

# ------------------------------------------------------------------------------
# 7. Initialise Ansible vault
# ------------------------------------------------------------------------------

VAULT_FILE="${INSTALL_DIR}/ansible/group_vars/all/vault.yml"
ANSIBLE_VAULT_BIN="${REAL_HOME}/.local/bin/ansible-vault"

if [[ -f "${VAULT_FILE}" ]]; then
    ok "Vault file already exists"
else
    info "Creating empty vault file..."
    tmp=$(sudo -u "${SUDO_USER}" mktemp)
    sudo -u "${SUDO_USER}" bash -c "echo '# Vault — add secrets here using: ansible-vault edit ansible/group_vars/vault.yml' > '${tmp}'"
    sudo -u "${SUDO_USER}" ANSIBLE_VAULT_PASSWORD_FILE="${VAULT_PASS_FILE}" \
        "${ANSIBLE_VAULT_BIN}" encrypt "${tmp}" --output="${VAULT_FILE}"
    rm "${tmp}"
    chown "${SUDO_USER}:${SUDO_USER}" "${VAULT_FILE}"
    ok "Vault file created at ${VAULT_FILE}"
fi

# ------------------------------------------------------------------------------
# 8. Storage group
# ------------------------------------------------------------------------------

STORAGE_DIR="/data/storage"
STORAGE_GROUP="storageUsers"

if getent group "${STORAGE_GROUP}" > /dev/null 2>&1; then
    ok "${STORAGE_GROUP} group already exists"
else
    info "Creating ${STORAGE_GROUP} group..."
    groupadd "${STORAGE_GROUP}"
    ok "${STORAGE_GROUP} group created"
fi

if id -nG "${SUDO_USER}" | grep -qw "${STORAGE_GROUP}"; then
    ok "${SUDO_USER} is already in ${STORAGE_GROUP}"
else
    info "Adding ${SUDO_USER} to ${STORAGE_GROUP}..."
    usermod -aG "${STORAGE_GROUP}" "${SUDO_USER}"
    ok "${SUDO_USER} added to ${STORAGE_GROUP}"
fi

info "Setting ownership and permissions on ${STORAGE_DIR}..."
chown -R root:"${STORAGE_GROUP}" "${STORAGE_DIR}"
chmod -R 2775 "${STORAGE_DIR}"
ok "Ownership and permissions set on ${STORAGE_DIR}"

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------

echo ""
info "Bootstrap complete. Next steps:"
echo "  1. Log out and back in (group membership for ${STORAGE_GROUP} requires a new session)"
echo "  2. tailscale up --advertise-routes=${TAILSCALE_SUBNET} --accept-dns=false"
echo "  3. cd ${INSTALL_DIR}"
echo "  4. Run the Ansible playbook to deploy services"
