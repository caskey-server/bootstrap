#!/usr/bin/env bash
# bootstrap.sh — One-shot server setup
# Usage: curl -fsSL https://raw.githubusercontent.com/caskey-server/bootstrap/main/bootstrap.sh | bash
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
apt-get install -y -qq git ansible gh

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

# Configure git credentials globally (read-only PAT, scoped to org)
git config --global url."https://x-access-token:$(gh auth token)@github.com/caskey-server/".insteadOf "https://github.com/caskey-server/"
info "Git credentials configured."

# ---------- generate .env files ----------
info "Checking service .env files..."

gen_password() {
    openssl rand -hex 16
}

gen_secret() {
    openssl rand -hex 32
}

generate_env() {
    local service_dir="$1"
    local env_file="$service_dir/.env"
    local service_name
    service_name=$(basename "$service_dir")

    if [[ -f "$env_file" ]]; then
        warn "$service_name/.env already exists — skipping."
        return
    fi

    case "$service_name" in
        gitea)
            cat > "$env_file" <<ENVEOF
# Gitea database
GITEA_DB_USER=gitea
GITEA_DB_PASSWORD=$(gen_password)
GITEA_DB_NAME=gitea
ENVEOF
            ;;
        romm)
            cat > "$env_file" <<ENVEOF
# RomM database
ROMM_DB_USER=romm
ROMM_DB_PASSWORD=$(gen_password)
ROMM_DB_ROOT_PASSWORD=$(gen_password)

# RomM auth
ROMM_AUTH_SECRET_KEY=$(gen_secret)

# Metadata providers (optional — edit later if needed)
SCREENSCRAPER_USER=
SCREENSCRAPER_PASSWORD=
STEAMGRIDDB_API_KEY=
IGDB_CLIENT_ID=
IGDB_CLIENT_SECRET=
ENVEOF
            ;;
        nginx-proxy-manager)
            cat > "$env_file" <<ENVEOF
# NPM database
NPM_DB_USER=npm
NPM_DB_PASSWORD=$(gen_password)
NPM_DB_ROOT_PASSWORD=$(gen_password)
ENVEOF
            ;;
        grafana)
            cat > "$env_file" <<ENVEOF
# Grafana admin
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$(gen_password)
ENVEOF
            ;;
        github-runner)
            cat > "$env_file" <<'ENVEOF'
# GitHub Actions Runner
# Generate at: https://github.com/organizations/caskey-server/settings/actions/runners/new
RUNNER_TOKEN=CHANGE_ME
RUNNER_NAME=nuc-runner
RUNNER_LABELS=self-hosted,linux,x64
ENVEOF
            ;;
        *)
            # No .env needed for this service
            return
            ;;
    esac

    info "Generated $service_name/.env with random credentials."
}

for service_dir in "$REPO_DIR"/services/*/; do
    generate_env "$service_dir"
done

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
