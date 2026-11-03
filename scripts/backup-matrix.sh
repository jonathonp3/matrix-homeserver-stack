#!/bin/bash
set -euo pipefail

# ===== CONFIG =====
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups/matrix}"
DATE=$(date +%Y%m%d-%H%M%S)
STAGE="$BACKUP_ROOT/stage-$DATE"
ARCHIVE="$BACKUP_ROOT/matrix-backup-$DATE.tar.gz"

# ===== PREREQUISITES =====
mkdir -p "$BACKUP_ROOT"
mkdir -p "$STAGE"

echo "==> Backing up to $ARCHIVE"

# ===== 1. STOP SYNAPSE FOR A CONSISTENT SQLITE BACKUP =====
echo "==> Stopping Synapse for consistent SQLite snapshot..."
systemctl --user stop synapse-compose.service
sleep 3

# ===== 2. SYNAPSE DATA =====
echo "==> Copying Synapse data..."
mkdir -p "$STAGE/matrix/data"
sudo cp -a ~/matrix/data/. "$STAGE/matrix/data/"
sudo chown -R "$USER:$USER" "$STAGE/matrix/data"

# ===== 3. COMPOSE FILES + CONFIGS =====
echo "==> Copying compose files and configs..."
mkdir -p "$STAGE/matrix"
cp -a ~/matrix/docker-compose.yml "$STAGE/matrix/"
cp -a ~/matrix/rtc "$STAGE/matrix/"

# ===== 4. CADDY =====
echo "==> Copying Caddyfile..."
mkdir -p "$STAGE/etc"
sudo cp -a /etc/caddy/Caddyfile "$STAGE/etc/Caddyfile"
sudo chown "$USER:$USER" "$STAGE/etc/Caddyfile"

# Caddy cert storage (optional; auto-renewable)
if [ -d /var/lib/caddy/.local/share/caddy ]; then
    echo "==> Copying Caddy certs..."
    sudo mkdir -p "$STAGE/var-lib-caddy"
    sudo cp -a /var/lib/caddy/.local/share/caddy/. "$STAGE/var-lib-caddy/"
    sudo chown -R "$USER:$USER" "$STAGE/var-lib-caddy"
fi

# ===== 5. SYSTEMD UNITS =====
echo "==> Copying systemd units..."
mkdir -p "$STAGE/systemd"
cp -a ~/.config/systemd/user/*.service "$STAGE/systemd/" 2>/dev/null || true

# ===== 6. DDNS + shell =====
echo "==> Copying user scripts..."
mkdir -p "$STAGE/home"
cp -a ~/update_domain.sh "$STAGE/home/" 2>/dev/null || true
cp -a ~/.bashrc "$STAGE/home/" 2>/dev/null || true
cp -a ~/.profile "$STAGE/home/" 2>/dev/null || true

# ===== 7. DOCKER INVENTORY =====
echo "==> Capturing docker state..."
{
    echo "# Docker images"
    docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}'
    echo
    echo "# Running containers"
    docker ps --format '{{.Names}}\t{{.Image}}'
    echo
    echo "# Compose projects"
    docker compose ls
} > "$STAGE/docker-state.txt" 2>&1 || true

# ===== 8. SYSTEM INFO =====
echo "==> Capturing system info..."
{
    echo "# uname"
    uname -a
    echo
    echo "# OS"
    cat /etc/os-release
    echo
    echo "# IP"
    hostname -I
    echo
    echo "# Listening TCP ports"
    sudo ss -tlnp 2>/dev/null | grep -E ':(80|443|3479|7880|7881|8008|8081) '
    echo
    echo "# Listening UDP ports"
    sudo ss -ulnp 2>/dev/null | grep -E ':(3479|5000[0-9]|5001[0-9]|50020|5030[0-9]|50310) '
} > "$STAGE/system-info.txt" 2>&1 || true

# ===== 9. RESTART SYNAPSE =====
echo "==> Restarting Synapse..."
systemctl --user start synapse-compose.service

# ===== 10. ARCHIVE =====
echo "==> Creating archive..."
cd "$BACKUP_ROOT"
tar -czf "$ARCHIVE" "stage-$DATE"

# ===== 11. CHECKSUM =====
echo "==> Computing checksum..."
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

# ===== 12. CLEANUP =====
echo "==> Cleaning up stage directory..."
rm -rf "$STAGE"

# ===== 13. INTEGRITY CHECK =====
if [ -x ~/matrix-homeserver-stack/scripts/check-backup.sh ] || [ -x ~/check-backup.sh ]; then
    CHECK_SCRIPT=$(command -v ~/matrix-homeserver-stack/scripts/check-backup.sh 2>/dev/null || echo ~/check-backup.sh)
    echo "==> Verifying backup integrity..."
    "$CHECK_SCRIPT" "$ARCHIVE" || {
        echo "❌ Backup integrity check failed — do not trust this backup"
        exit 1
    }
fi

# ===== 14. REPORT =====
SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo
echo "✓ Backup complete"
echo "  Archive:  $ARCHIVE"
echo "  Size:     $SIZE"
echo "  Checksum: $(cat "$ARCHIVE.sha256")"
