#!/bin/bash
set -euo pipefail

# ===== Docker =====
echo "==> Installing Docker..."

# Clean up any old repo config
sudo rm -rf /etc/apt/sources.list.d/docker.list.disabled
sudo rm -rf /etc/apt/sources.list.d/docker.list*

sudo apt update
sudo apt -y install ca-certificates curl gnupg lsb-release

# Docker GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

# Docker repo
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"

echo "==> Docker installed"
docker --version
docker compose version

# ===== Caddy =====
echo "==> Installing Caddy..."

# Caddy GPG key
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
    sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

# Caddy repo
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
    sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

sudo apt update
sudo apt install -y caddy

echo "==> Caddy installed"
caddy version

# ===== Verification =====
echo "==> Verifying installations..."
echo
echo "Docker:  $(docker --version)"
echo "Compose: $(docker compose version --short)"
echo "Caddy:   $(caddy version)"
echo

# ===== Next steps =====
echo "=========================================="
echo "Installation complete"
echo "=========================================="
echo
echo "Next steps:"
echo "  1. Log out and back in for the docker group change to take effect"
echo "  2. Verify Docker:    docker run --rm hello-world"
echo "  3. Verify Caddy:     sudo systemctl status caddy"
echo "  4. Deploy the stack: follow docs/INSTALL.md"
echo
echo "Caddy is running but has no config yet — it will fail to serve"
echo "anything until you copy caddy/Caddyfile.example to /etc/caddy/Caddyfile"
echo "and replace the placeholders."
