# Server Bootstrap Script

Prepares a fresh Ubuntu Server server stack. Installs all prerequisites and clones the server repo ready for Ansible deployment.

## Running the Script

### Option 1: curl (no clone needed)

```sh
curl -fsSL https://raw.githubusercontent.com/caskey-server/bootstrap/main/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

### Option 2: Git clone

```sh
git clone https://github.com/caskey-server/bootstrap.git
cd bootstrap
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

### After Running

1. `cd /opt/server`
2. Run the Ansible playbook to deploy services

## What this Script Does

1. Installs Docker
2. Installs Tailscale
3. Installs Ansible
4. Clones the server repo (and submodules)