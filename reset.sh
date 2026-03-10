#!/usr/bin/env bash
# reset.sh — Tear down everything back to a clean Ubuntu install
# Does NOT uninstall Docker, Tailscale, Ansible, or gh CLI
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
    exit 1
fi

echo -e "${RED}"
echo "============================================"
echo "  This will destroy ALL containers, volumes,"
echo "  service data, and the server repo clone."
echo "============================================"
echo -e "${NC}"
read -rp "Type 'reset' to confirm: " confirm </dev/tty

if [[ "$confirm" != "reset" ]]; then
    error "Aborted."
    exit 1
fi

# ---------- stop and remove all containers ----------
info "Stopping all containers..."
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm $(docker ps -aq) 2>/dev/null || true

# ---------- remove Docker state ----------
info "Removing Docker networks, images, and volumes..."
docker network rm docker-bridge 2>/dev/null || true
docker system prune -af --volumes

# ---------- remove service data ----------
info "Removing service data..."
rm -rf /data/local/volumes/*

# ---------- remove repo clone ----------
info "Removing /opt/server..."
rm -rf /opt/server

# ---------- wipe git config ----------
info "Wiping global git config..."
rm -f /root/.gitconfig

# ---------- deauth gh CLI ----------
info "Logging out of GitHub CLI..."
gh auth logout --hostname github.com 2>/dev/null || true

info "Reset complete. Run bootstrap.sh to start fresh."
