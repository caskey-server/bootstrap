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
#    0. Verify environment, data drive mount, and refresh package lists
#    1. Install Docker (+ log rotation)
#    2. Install Tailscale
#    3. Configure networking (for Tailscale subnet routing)
#    4. Install Ansible
#    5. Clone orchestrator repo
#    6. Install SOPS
#    7. Install Age
#    8. Configure Age (generate key + back-up reminder)
#    9. Configure storage group and permissions
#   10. Set passwordless sudo
#   11. Install BlueZ (Bluetooth Driver)
#   12. Install Firefox + xauth (for SSH X11 forwarding)
#
# NOTES:
#     - This script is idempotent and can be safely re-run.
#     - This script is hand rolled, but Claude Code was used
#       extensively to get both the core structure and content required
# ==============================================================================

SERVER_REPO_ORG="caskey-server"
SERVER_REPO_NAME="orchestrator"
INSTALL_DIR="/opt/server/orchestrator"
TAILSCALE_SUBNET="192.168.1.0/24"

# Flags used by the post-bootstrap "Next steps" output to decide which manual
# actions are still pending versus already complete.
GROUPS_CHANGED=0
AGE_KEY_NEW=0


# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

command_exists() { command -v "$1" &> /dev/null; }


# ------------------------------------------------------------------------------
# 0.1. Verify environment (running as sudo user)
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
# 0.2. Verify data drive is mounted at /data
# ------------------------------------------------------------------------------

if mountpoint -q /data 2>/dev/null || mountpoint -q /data/storage 2>/dev/null; then
    ok "Data drive is mounted"
else
    error "Data drive is not mounted at /data or /data/storage.
        Mount it (and add an /etc/fstab entry) before running bootstrap.
        Run 'lsblk' to find the device, then for example:
          sudo mkdir -p /data
          sudo mount /dev/sdX1 /data
          echo 'UUID=<uuid>  /data  ext4  defaults  0  2' | sudo tee -a /etc/fstab"
fi


# ------------------------------------------------------------------------------
# 0.3. Update package lists once for the whole run
# ------------------------------------------------------------------------------

info "Updating package lists..."
apt-get update -qq
ok "Package lists updated"


# ------------------------------------------------------------------------------
# 1. Install Docker
# ------------------------------------------------------------------------------

if command_exists docker; then
    ok "Docker is already installed ($(docker --version))"
else
    info "Installing Docker..."

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
    GROUPS_CHANGED=1
    ok "${SUDO_USER} added to the docker group"
fi

# Configure Docker log rotation so a chatty container can't fill /var/lib/docker
DAEMON_JSON="/etc/docker/daemon.json"
if [[ -f "${DAEMON_JSON}" ]] && grep -q '"max-size"' "${DAEMON_JSON}"; then
    ok "Docker log rotation already configured"
else
    info "Configuring Docker log rotation..."
    mkdir -p /etc/docker
    cat > "${DAEMON_JSON}" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker
    ok "Docker log rotation configured (10m × 3 files per container)"
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

    apt-get update -qq  # refresh after adding Tailscale source
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
        apt-get install -y -qq pipx
        sudo -u "${SUDO_USER}" pipx ensurepath
    fi

    sudo -u "${SUDO_USER}" pipx install --include-deps ansible
    ok "Ansible installed"
fi

info "Injecting Ansible Python dependencies..."
sudo -u "${SUDO_USER}" pipx inject ansible passlib "bcrypt==4.0.1" docker requests lxml --force
ok "Ansible Python dependencies injected"


# ------------------------------------------------------------------------------
# 5. Clone orchestrator repo
# ------------------------------------------------------------------------------

if [[ -d "${INSTALL_DIR}/.git" ]]; then
    ok "Orchestrator repo already cloned at ${INSTALL_DIR}"
else
    info "Cloning orchestrator repo to ${INSTALL_DIR}..."
    info "A fine-grained PAT with read-only 'Contents' access to caskey-server/* is enough."

    read -rsp "GitHub PAT: " GITHUB_PAT
    echo

    if [[ -z "${GITHUB_PAT}" ]]; then
        error "PAT cannot be empty"
    fi

    # Store the PAT in the credential store so Git (and Ansible's per-service clones) doesn't prompt
    sudo -u "${SUDO_USER}" HOME="${USER_HOME}" git config --global credential.helper store
    sudo -u "${SUDO_USER}" bash -c "echo 'https://git:${GITHUB_PAT}@github.com' > '${USER_HOME}/.git-credentials'"
    chmod 0600 "${USER_HOME}/.git-credentials"
    chown "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.git-credentials"

    mkdir -p "${INSTALL_DIR}"
    chown "${SUDO_USER}:${SUDO_USER}" "$(dirname "${INSTALL_DIR}")" "${INSTALL_DIR}"

    sudo -u "${SUDO_USER}" HOME="${USER_HOME}" git clone \
        "https://github.com/${SERVER_REPO_ORG}/${SERVER_REPO_NAME}.git" \
        "${INSTALL_DIR}"

    chown -R "${SUDO_USER}:${SUDO_USER}" "${INSTALL_DIR}"

    ok "Orchestrator repo cloned to ${INSTALL_DIR}"
fi


# ------------------------------------------------------------------------------
# 6. Install SOPS
# ------------------------------------------------------------------------------

SOPS_VERSION="3.10.2"

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
else
    info "Generating new age key for secret decryption..."

    mkdir -p "$(dirname "${AGE_KEY_FILE}")"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.config"

    sudo -u "${SUDO_USER}" age-keygen -o "${AGE_KEY_FILE}"
    chmod 0400 "${AGE_KEY_FILE}"

    AGE_KEY_NEW=1
    ok "age key generated"
fi

# Pull the public key out of keys.txt for the post-bootstrap reminder below
AGE_PUBLIC_KEY=$(sudo -u "${SUDO_USER}" grep '^# public key: ' "${AGE_KEY_FILE}" | sed 's/^# public key: //')


# ------------------------------------------------------------------------------
# 9. Configure storage group
# ------------------------------------------------------------------------------

STORAGE_DIR="/data/storage"
STORAGE_GROUP="storageUsers"
STORAGE_GID="1001"  # must match storage_users_gid in ansible group_vars/all.yml

if getent group "${STORAGE_GROUP}" > /dev/null 2>&1; then
    existing_gid=$(getent group "${STORAGE_GROUP}" | cut -d: -f3)
    if [[ "${existing_gid}" != "${STORAGE_GID}" ]]; then
        error "${STORAGE_GROUP} exists but with gid ${existing_gid} (expected ${STORAGE_GID}). Fix manually before re-running."
    fi
    ok "${STORAGE_GROUP} group already exists (gid ${STORAGE_GID})"
else
    info "Creating ${STORAGE_GROUP} group (gid ${STORAGE_GID})..."
    groupadd -g "${STORAGE_GID}" "${STORAGE_GROUP}"
    ok "${STORAGE_GROUP} group created"
fi

if id -nG "${SUDO_USER}" | grep -qw "${STORAGE_GROUP}"; then
    ok "${SUDO_USER} is already in ${STORAGE_GROUP}"
else
    info "Adding ${SUDO_USER} to ${STORAGE_GROUP}..."
    usermod -aG "${STORAGE_GROUP}" "${SUDO_USER}"
    GROUPS_CHANGED=1
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
# 10. Add passwordless sudo for deploy user
# ------------------------------------------------------------------------------

echo "${SUDO_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${SUDO_USER}
chmod 0440 /etc/sudoers.d/${SUDO_USER}


# ------------------------------------------------------------------------------
# 11. BlueZ
# ------------------------------------------------------------------------------


if dpkg -s bluez >/dev/null 2>&1; then
    ok "BlueZ already installed"
else
    info "Installing BlueZ..."
    apt-get install -y -qq bluez
    ok "BlueZ installed"
fi

if systemctl is-active --quiet bluetooth; then
    ok "BlueZ service already running"
else
    info "Enabling and starting bluetooth.service..."
    systemctl enable --now bluetooth
    ok "BlueZ service running"
fi


# ------------------------------------------------------------------------------
# 12. Firefox (and xauth for x11 forwarding)
# ------------------------------------------------------------------------------


if dpkg -s xauth >/dev/null 2>&1; then
    ok "xauth already installed"
else
    info "Installing xauth (required for SSH X11 forwarding)..."
    apt-get install -y -qq xauth
    ok "xauth installed"
fi

MOZILLA_SOURCES="/etc/apt/sources.list.d/mozilla.sources"
if [[ -f "${MOZILLA_SOURCES}" ]] && command_exists firefox; then
    ok "Firefox already installed from Mozilla apt repo ($(firefox --version 2>/dev/null))"
else
    info "Installing Firefox from Mozilla apt repository..."

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc
    chmod a+r /etc/apt/keyrings/packages.mozilla.org.asc

    tee "${MOZILLA_SOURCES}" <<EOF >/dev/null
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF

    # Pin Mozilla above the Ubuntu snap transition package so `apt install
    # firefox` picks the real .deb.
    cat > /etc/apt/preferences.d/mozilla <<EOF
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

    apt-get update -qq
    apt-get install -y -qq firefox

    ok "Firefox installed ($(firefox --version 2>/dev/null))"
fi


# ------------------------------------------------------------------------------
# Manual post-bootstrap actions
# ------------------------------------------------------------------------------

echo ""
info "Bootstrap complete. Next steps:"

# 1. Age key backup — soft check: if the key was pre-existing, assume it
#    was backed up on the original run.
if [[ "${AGE_KEY_NEW}" -eq 1 ]]; then
    echo "  1. Back up the age private key (see instructions below)"
else
    echo "  1. [DONE] Age key was pre-existing — verify your backup if you haven't"
fi

# 2. Logout — only needed if usermod ran this run.
if [[ "${GROUPS_CHANGED}" -eq 1 ]]; then
    echo "  2. Log out and back in (group membership requires a new session)"
else
    echo "  2. [DONE] No group changes this run — current session is fine"
fi

# 3. Tailscale subnet route — check current prefs.
if tailscale debug prefs 2>/dev/null | grep -q "${TAILSCALE_SUBNET}"; then
    echo "  3. [DONE] Tailscale subnet route ${TAILSCALE_SUBNET} already advertised"
else
    echo "  3. Run: sudo tailscale up --advertise-routes=${TAILSCALE_SUBNET} --accept-dns=false"
fi

echo "  4. Run: cd ${INSTALL_DIR}"
echo "  5. Run: ansible-playbook ansible/playbooks/server.yml"
echo ""
echo "============================================================"
echo "  Backing up age private key"
echo "============================================================"
echo "  Age key location: ${AGE_KEY_FILE}"
echo "  Copy it to a password manager or off-host storage:"
echo "    On this host:    sudo cat ${AGE_KEY_FILE}"
echo "    From elsewhere:  scp ${SUDO_USER}@<host>:${AGE_KEY_FILE} ./"
echo ""
echo "  Public key (paste into orchestrator's .sops.yaml):"
echo "    ${AGE_PUBLIC_KEY}"
echo "============================================================"
