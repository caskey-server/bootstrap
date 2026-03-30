#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# bootstrap.sh
#
# Prepare a fresh Ubuntu Server.
#
# Pre-requisites:
#   - Ubuntu Server 24.04 or later
#   - Ability to run as a sudo user
#   - GitHub PAT with access to the repository defined below
#
# Steps:
#   0. Verify environment
#   1. Install Docker
#   2. Install Tailscale
#   3. Configure networking (for Tailscale subnet routing)
#   4. Install Ansible
#   5. Clone server repo
#   6. Install SOPS
#   7. Install Age
#   8. Configure Age
#
# NOTE: This script is idempotent and can be safely re-run.
# ==============================================================================

SERVER_REPO_ORG="caskey-server"
SERVER_REPO_NAME="server"
INSTALL_DIR="/opt/server"
TAILSCALE_SUBNET="192.168.1.0/24"


# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

command_exists() { command -v "$1" &> /dev/null; }


# ------------------------------------------------------------------------------
# 0. Verify environment (running as sudo user)
# ------------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    error "This script must be run as root (sudo ./bootstrap.sh)"
fi

SUDO_USER="${SUDO_USER:-}"
if [[ -z "${SUDO_USER}" ]]; then
    error "Run with sudo, not as a direct root login"
fi

USER_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)


# ------------------------------------------------------------------------------
# 1. Install Docker
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

if id -nG "${SUDO_USER}" | grep -qw docker; then
    ok "${SUDO_USER} is already in the docker group"
else
    info "Adding ${SUDO_USER} to the docker group..."
    usermod -aG docker "${SUDO_USER}"
    ok "${SUDO_USER} added to the docker group"
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
    sudo -u "${SUDO_USER}" HOME="${USER_HOME}" git config --global credential.helper store
    sudo -u "${SUDO_USER}" bash -c "echo 'https://git:${GITHUB_PAT}@github.com' > '${USER_HOME}/.git-credentials'"
    chmod 0600 "${USER_HOME}/.git-credentials"
    chown "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.git-credentials"

    mkdir -p "${INSTALL_DIR}"
    chown "${SUDO_USER}:${SUDO_USER}" "${INSTALL_DIR}"

    sudo -u "${SUDO_USER}" HOME="${USER_HOME}" git clone --recurse-submodules \
        "https://github.com/${SERVER_REPO_ORG}/${SERVER_REPO_NAME}.git" \
        "${INSTALL_DIR}"

    chown -R "${SUDO_USER}:${SUDO_USER}" "${INSTALL_DIR}"

    ok "Server repo cloned to ${INSTALL_DIR}"
fi


# ------------------------------------------------------------------------------
# 6. Install SOPS
# ------------------------------------------------------------------------------

SOPS_VERSION="3.9.4"

# Install sops and age if not present
if command_exists sops; then
    ok "sops is already installed"
else
    info "Installing sops..."
    curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
        -o /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
    ok "sops installed"
fi


# ------------------------------------------------------------------------------
# 7. Install Age
# ------------------------------------------------------------------------------

AGE_VERSION="1.2.1"

if command_exists age; then
    ok "age is already installed"
else
    info "Installing age..."
    tmp_dir=$(mktemp -d)
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
        | tar xz -C "${tmp_dir}"
    cp "${tmp_dir}/age/age" /usr/local/bin/age
    cp "${tmp_dir}/age/age-keygen" /usr/local/bin/age-keygen
    chmod +x /usr/local/bin/age /usr/local/bin/age-keygen
    rm -rf "${tmp_dir}"
    ok "age installed"
fi


# ------------------------------------------------------------------------------
# 8. Configure Age
# ------------------------------------------------------------------------------

AGE_KEY_FILE="${USER_HOME}/.config/sops/age/keys.txt"

if [[ -f "${AGE_KEY_FILE}" ]]; then
    ok "age key already exists at ${AGE_KEY_FILE}"
    
    # Display the public key for reference
    info "Your age public key (for encrypting secrets):"
    sudo -u "${SUDO_USER}" grep "^# public key: " "${AGE_KEY_FILE}" | sed 's/# public key: /  /'
else
    info "Generating new age key for secret decryption..."
    
    mkdir -p "$(dirname "${AGE_KEY_FILE}")"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.config"
    
    # Generate new age key pair as the sudo user
    sudo -u "${SUDO_USER}" age-keygen -o "${AGE_KEY_FILE}"
    
    chmod 0400 "${AGE_KEY_FILE}"

    ok "age key generated and saved to ${AGE_KEY_FILE}"
    
    # Display the public key for reference
    info "Your age public key (for encrypting secrets):"
    sudo -u "${SUDO_USER}" grep "^# public key: " "${AGE_KEY_FILE}" | sed 's/# public key: /  /'
fi


# ------------------------------------------------------------------------------
# 9. Configure storage group
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

if [[ ! -d "${STORAGE_DIR}" ]]; then
    info "Creating ${STORAGE_DIR}..."
    mkdir -p "${STORAGE_DIR}"
    ok "${STORAGE_DIR} created"
fi

info "Setting ownership and permissions on ${STORAGE_DIR}..."
chown -R root:"${STORAGE_GROUP}" "${STORAGE_DIR}"
chmod -R 2775 "${STORAGE_DIR}"
ok "Ownership and permissions set on ${STORAGE_DIR}"


# ------------------------------------------------------------------------------
# Manual post-bootstrap actions
# ------------------------------------------------------------------------------

echo ""
info "Bootstrap complete. Next steps:"
echo "  1. Log out and back in (group membership requires a new session)"
echo "  2. Run: sudo tailscale up --advertise-routes=${TAILSCALE_SUBNET} --accept-dns=false"
echo "  3. Run: cd ${INSTALL_DIR}"
echo "  4. Run the Ansible playbook to deploy services"
