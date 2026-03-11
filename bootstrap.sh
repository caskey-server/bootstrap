#!/usr/bin/env bash
# bootstrap.sh — One-shot server setup
# Usage: curl -fsSL https://raw.githubusercontent.com/caskey-server/bootstrap/main/bootstrap.sh | sudo bash
set -euo pipefail

REPO_DIR="/opt/server"
REPO_URL="caskey-server/server"

# ---------- colours ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- root check ----------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
    exit 1
fi

# ---------- install dependencies ----------
info "Installing dependencies..."

# GitHub CLI
if ! command -v gh &>/dev/null; then
    info "Adding GitHub CLI APT repository..."
    mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
fi

apt-get update -qq
apt-get install -y -qq git ansible gh apache2-utils

# ---------- GitHub auth ----------
if ! gh auth status &>/dev/null; then
    if [[ -z "${GITHUB_PAT:-}" ]]; then
        read -rsp "Enter GitHub PAT for caskey-server org: " GITHUB_PAT </dev/tty
        echo
    fi

    if [[ -z "$GITHUB_PAT" ]]; then
        error "GITHUB_PAT is empty. Cannot authenticate."
        exit 1
    fi

    echo "$GITHUB_PAT" | gh auth login --with-token
    info "GitHub CLI authenticated."
else
    info "GitHub CLI already authenticated — skipping."
fi

# ---------- verify PAT scope ----------
info "Verifying PAT has access to caskey-server org..."
if ! gh api "orgs/caskey-server/repos" --silent 2>/dev/null; then
    error "PAT cannot access caskey-server org repos."
    error "Ensure the token has Contents:Read scope for the caskey-server org."
    exit 1
fi
info "PAT scope verified."

# ---------- AdGuard credentials ----------
info "AdGuard Home admin credentials"
read -rp "  AdGuard admin username: " ADGUARD_USER </dev/tty
while true; do
    read -rsp "  AdGuard admin password: " ADGUARD_PASS </dev/tty
    echo
    read -rsp "  Confirm password: " ADGUARD_PASS_CONFIRM </dev/tty
    echo
    if [[ "$ADGUARD_PASS" == "$ADGUARD_PASS_CONFIRM" ]]; then
        break
    fi
    warn "Passwords do not match — try again."
done
ADGUARD_HASH=$(htpasswd -nbBC 10 "" "$ADGUARD_PASS" | cut -d: -f2)

# ---------- clone server repo ----------
if [[ -d "$REPO_DIR/.git" ]]; then
    info "Server repo already cloned at $REPO_DIR — pulling latest..."
    cd "$REPO_DIR"
    git pull --recurse-submodules
    git submodule update --init --recursive
else
    info "Cloning server repo to $REPO_DIR..."
    gh repo clone "$REPO_URL" "$REPO_DIR" -- --recurse-submodules
fi

# Configure git credentials scoped to this repo only
git -C "$REPO_DIR" config url."https://x-access-token:$(gh auth token)@github.com/caskey-server/".insteadOf "https://github.com/caskey-server/"
info "Git credentials configured (repo-scoped)."

# Verify submodules cloned successfully
info "Verifying submodules..."
missing_submodules=()
while IFS= read -r submodule_path; do
    if [[ ! -f "$REPO_DIR/$submodule_path/docker-compose.yml" ]]; then
        missing_submodules+=("$submodule_path")
    fi
done < <(git -C "$REPO_DIR" config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

if [[ ${#missing_submodules[@]} -gt 0 ]]; then
    error "The following submodules failed to clone:"
    for m in "${missing_submodules[@]}"; do
        error "  - $m"
    done
    exit 1
fi
info "All submodules present."

# ---------- generate .env files ----------
info "Checking service .env files..."

check_env_drift() {
    local service_dir="$1"
    local template="$service_dir/.env.template"
    local env_file="$service_dir/.env"
    local service_name
    service_name=$(basename "$service_dir")

    [[ -f "$template" ]] || return 0
    [[ -f "$env_file" ]] || return 0

    local template_keys env_keys missing
    template_keys=$(grep -oP '^[A-Za-z_][A-Za-z0-9_]*(?==)' "$template" | sort)
    env_keys=$(grep -oP '^[A-Za-z_][A-Za-z0-9_]*(?==)' "$env_file" | sort)
    missing=$(comm -23 <(echo "$template_keys") <(echo "$env_keys"))

    if [[ -n "$missing" ]]; then
        warn "$service_name/.env is missing keys from template:"
        while IFS= read -r key; do
            warn "  - $key"
        done <<< "$missing"
    fi
}

generate_env() {
    local service_dir="$1"
    local template="$service_dir/.env.template"
    local env_file="$service_dir/.env"
    local service_name
    service_name=$(basename "$service_dir")

    [[ -f "$template" ]] || return 0

    if [[ -f "$env_file" ]]; then
        warn "$service_name/.env already exists — skipping generation."
        check_env_drift "$service_dir"
        return
    fi

    local content
    content=$(cat "$template")

    # Replace each placeholder with a unique random value
    while [[ "$content" == *"%%RANDOM_PASSWORD%%"* ]]; do
        content="${content/%%RANDOM_PASSWORD%%/$(openssl rand -hex 16)}"
    done
    while [[ "$content" == *"%%RANDOM_SECRET%%"* ]]; do
        content="${content/%%RANDOM_SECRET%%/$(openssl rand -hex 32)}"
    done

    echo "$content" > "$env_file"
    info "Generated $service_name/.env from template."
}

for service_dir in "$REPO_DIR"/services/*/; do
    generate_env "$service_dir"
done

# ---------- generate AdGuard config ----------
ADGUARD_CONF="$REPO_DIR/services/adguard/config/AdGuardHome.yaml"
ADGUARD_TMPL="$REPO_DIR/services/adguard/config/AdGuardHome.yaml.template"

if [[ -f "$ADGUARD_CONF" ]]; then
    warn "AdGuardHome.yaml already exists — skipping."
else
    info "Generating AdGuard Home config..."
    sed -e "s|%%ADGUARD_USER%%|${ADGUARD_USER}|g" \
        -e "s|%%ADGUARD_HASH%%|${ADGUARD_HASH}|g" \
        "$ADGUARD_TMPL" > "$ADGUARD_CONF"
    info "Generated AdGuard Home config with pre-seeded credentials."
fi

# ---------- run Ansible ----------
info "Running Ansible playbook..."
cd "$REPO_DIR"
ansible-playbook -c local ansible/site.yml

info "Bootstrap complete!"
echo ""
echo "============================================"
echo "  Manual steps required to finish setup."
echo "  See: $REPO_DIR/README.md"
echo ""
echo "  Quick view: cat $REPO_DIR/README.md"
echo "============================================"
