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

# Configure git credentials globally so submodule fetches work
git config --global url."https://x-access-token:$(gh auth token)@github.com/caskey-server/".insteadOf "https://github.com/caskey-server/"
info "Git credentials configured (global)."

# ---------- verify PAT scope ----------
info "Verifying PAT has access to caskey-server org..."
if ! gh api "orgs/caskey-server/repos" --silent 2>/dev/null; then
    error "PAT cannot access caskey-server org repos."
    error "Ensure the token has Contents:Read scope for the caskey-server org."
    exit 1
fi
info "PAT scope verified."

# ---------- clone server repo ----------
if [[ -d "$REPO_DIR/.git" ]]; then
    info "Server repo already cloned at $REPO_DIR — pulling latest..."
    cd "$REPO_DIR"
    git pull --recurse-submodules
    git submodule update --init --recursive
    git submodule foreach 'git fetch origin && git checkout main && git reset --hard origin/main'
else
    info "Cloning server repo to $REPO_DIR..."
    gh repo clone "$REPO_URL" "$REPO_DIR" -- --recurse-submodules
fi

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
drift_services=()
env_secrets_needed=()


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
        drift_services+=("$service_name")
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

    if [[ ! -f "$template" ]]; then
        info "$service_name — no .env.template, skipping."
        return 0
    fi

    if [[ -f "$env_file" ]]; then
        info "$service_name/.env already exists — checking for drift..."
        check_env_drift "$service_dir"
        return
    fi

    info "$service_name — generating .env from template..."
    cp "$template" "$env_file"
    while grep -q 'GENERATE_PASSWORD' "$env_file"; do
        local rand
        rand=$(xxd -l 16 -p -c 256 /dev/urandom)
        sed -i "0,/GENERATE_PASSWORD/{s/GENERATE_PASSWORD/$rand/}" "$env_file"
    done
    while grep -q 'GENERATE_SECRET' "$env_file"; do
        local rand
        rand=$(xxd -l 32 -p -c 256 /dev/urandom)
        sed -i "0,/GENERATE_SECRET/{s/GENERATE_SECRET/$rand/}" "$env_file"
    done
    # Check for values that still need manual input
    local manual_keys
    manual_keys=$(grep -E '=(CHANGE_ME|PASTE_[A-Z_]+_HERE)$' "$env_file" \
        | grep -oP '^[A-Za-z_][A-Za-z0-9_]*(?==)' || true)
    if [[ -n "$manual_keys" ]]; then
        env_secrets_needed+=("$service_name")
    fi
    info "$service_name/.env generated."
}

for service_dir in "$REPO_DIR"/services/*/; do
    generate_env "$service_dir"
done

# ---------- generate AdGuard config ----------
ADGUARD_CONF="$REPO_DIR/services/adguard/config/AdGuardHome.yaml"
ADGUARD_TMPL="$REPO_DIR/services/adguard/config/AdGuardHome.yaml.template"

if [[ -f "$ADGUARD_CONF" ]]; then
    info "AdGuardHome.yaml already exists — skipping."
else
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

    info "Generating AdGuardHome.yaml from template..."
    escaped_hash=$(printf '%s' "$ADGUARD_HASH" | sed 's/[&\\]/\\&/g')
    sed -e "s|%%ADGUARD_USER%%|${ADGUARD_USER}|g" \
        -e "s|%%ADGUARD_HASH%%|${escaped_hash}|g" \
        "$ADGUARD_TMPL" > "$ADGUARD_CONF"
    info "Generated AdGuard Home config with pre-seeded credentials."
fi

# ---------- run Ansible ----------
info "Running Ansible playbook..."
cd "$REPO_DIR"
ansible-playbook -c local ansible/site.yml

# ---------- post-bootstrap summary ----------
info "Bootstrap complete!"

post_steps=()

if ! tailscale status &>/dev/null; then
    post_steps+=("$(cat <<'STEP'
• Tailscale — Authenticate and advertise the LAN subnet, then
  approve the route in the Tailscale admin console:
  sudo tailscale up --advertise-routes=192.168.1.0/24 --accept-dns=false
STEP
)")
fi

if [[ ${#env_secrets_needed[@]} -gt 0 ]]; then
    secrets_msg="• .env secrets — The following services have .env files"
    secrets_msg+=$'\n'"  with placeholder values that need setting manually:"
    for svc in "${env_secrets_needed[@]}"; do
        secrets_msg+=$'\n'"  - $svc"
    done
    post_steps+=("$secrets_msg")
fi

if [[ ${#drift_services[@]} -gt 0 ]]; then
    drift_msg="• .env drift — The following services have .env files"
    drift_msg+=$'\n'"  missing keys from their templates. Review the warnings"
    drift_msg+=$'\n'"  above and manually add the missing keys:"
    for svc in "${drift_services[@]}"; do
        drift_msg+=$'\n'"  - $svc"
    done
    post_steps+=("$drift_msg")
fi

echo ""
echo "============================================"
if [[ ${#post_steps[@]} -gt 0 ]]; then
    echo "  Manual steps required to finish setup."
    echo "============================================"
    echo ""
    for step in "${post_steps[@]}"; do
        echo "$step"
        echo ""
    done
    echo "  See also: $REPO_DIR/README.md"
else
    echo "  No manual steps required."
    echo "============================================"
fi
