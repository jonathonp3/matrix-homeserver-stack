# Backup and Restore

Complete guide to backing up and restoring `matrix-homeserver-stack`.

**Golden rule:** never trust a backup you haven't verified. Run `scripts/check-backup.sh` after every backup. If it exits non-zero, re-run the backup — don't rely on a broken one.

---

## Part 1 — What to back up

### 1.1 Critical files

| File | Server path | What it is |
|---|---|---|
| `homeserver.db` | `~/matrix/data/homeserver.db` | All messages, users, rooms |
| `homeserver.yaml` | `~/matrix/data/homeserver.yaml` | Synapse config (contains all secrets) |
| `*.signing.key` | `~/matrix/data/matrix.example.com.signing.key` | Homeserver identity |
| `lk-jwt-as.yaml` | `~/matrix/data/lk-jwt-as.yaml` | AS registration (contains AS/HS tokens) |
| `media_store/` | `~/matrix/data/media_store/` | Uploaded images, videos, files |
| `docker-compose.yml` | `~/matrix/docker-compose.yml` | Synapse compose |
| `livekit.yaml` | `~/matrix/rtc/livekit/livekit.yaml` | LiveKit config (contains API keys) |
| `.env` | `~/matrix/rtc/lk-jwt/.env` | lk-jwt secrets (contains AS/HS tokens) |
| `docker-compose.yml` | `~/matrix/rtc/docker-compose.yml` | RTC compose |
| `Caddyfile` | `/etc/caddy/Caddyfile` | Reverse proxy config |
| `*.service` | `~/.config/systemd/user/*.service` | Systemd units |
| `update_domain.sh` | `~/update_domain.sh` | DDNS script |

### 1.2 Optional but useful

| File | Server path | Why |
|---|---|---|
| Caddy certs | `/var/lib/caddy/.local/share/caddy/` | Avoid re-issuing Let's Encrypt certs on restore |
| Shell profiles | `~/.bashrc`, `~/.profile` | Environment variables, aliases |

### 1.3 Not backed up (re-downloadable)

| File | Why |
|---|---|
| Docker images | `docker compose pull` on restore |
| Container layers | Rebuilt from images |
| Nextcloud / Syncthing data | Separate backup (not part of this stack) |
| Logs | Not needed |

---

## Part 2 — Backup procedure

### 2.1 The backup script

The repo includes `scripts/backup-matrix.sh`. Copy it to `~/` and make it executable:

```bash
cp ~/matrix-homeserver-stack/scripts/backup-matrix.sh ~/
chmod +x ~/backup-matrix.sh
```

### 2.2 Run the backup

```bash
~/backup-matrix.sh
```

Output:

```text
==> Backing up to /home/jonathon/backups/matrix/matrix-backup-20261103-143022.tar.gz
==> Stopping Synapse for consistent SQLite snapshot...
==> Copying Synapse data...
==> Copying compose files and configs...
==> Copying Caddyfile...
==> Copying systemd units...
==> Copying user scripts...
==> Capturing docker state...
==> Capturing system info...
==> Restarting Synapse...
==> Creating archive...
==> Computing checksum...
==> Cleaning up stage directory...
==> Verifying backup integrity...
  ✓ Checksum: a0bccd20...
  ✓ 9 critical files present
  ✓ Database integrity: ok
  ✓ Signing key: valid ed25519
  ✓ Backup is complete and valid

✓ Backup complete
  Archive:  /home/jonathon/backups/matrix/matrix-backup-20261103-143022.tar.gz
  Size:     19M
  Checksum: a0bccd20...
```

The script:

1. Stops Synapse (for a consistent SQLite snapshot)
2. Copies all critical files into a staging directory
3. Captures Docker state and system info
4. Restarts Synapse
5. Creates a `.tar.gz` archive
6. Computes a `.sha256` checksum
7. Runs `check-backup.sh` on the archive
8. Exits non-zero if anything failed

### 2.3 Verify the backup

If the script didn't run the integrity check (or you want to re-check):

```bash
~/matrix-homeserver-stack/scripts/check-backup.sh \
    ~/backups/matrix/matrix-backup-20261103-143022.tar.gz
```

Expected:

```text
✓ Checksum: a0bccd20...
✓ 9 critical files present
✓ Database integrity: ok
✓ Signing key: valid ed25519
✓ Backup is complete and valid
```

### 2.4 Encrypt the backup

The archive contains every secret in the stack: signing key, AS/HS tokens, LiveKit API secret, Synapse secrets. **Always encrypt before storing off-site.**

```bash
cd ~/backups/matrix

# Encrypt with GPG (AES256, password-based)
gpg --symmetric --cipher-algo AES256 matrix-backup-20261103-143022.tar.gz

# Verify decryption works
gpg -d matrix-backup-20261103-143022.tar.gz.gpg | tar -tzf - | head -3

# Remove unencrypted original
rm matrix-backup-20261103-143022.tar.gz

# Update checksum for the encrypted file
sha256sum matrix-backup-20261103-143022.tar.gz.gpg > matrix-backup-20261103-143022.tar.gz.gpg.sha256
rm matrix-backup-20261103-143022.tar.gz.sha256

# Verify
ls -lh
```

Expected:

```text
matrix-backup-20261103-143022.tar.gz.gpg
matrix-backup-20261103-143022.tar.gz.gpg.sha256
```

**Store the passphrase in a password manager.** Without it, the backup is unrecoverable.

### 2.5 Store off-site

Copy the encrypted archive to at least one other location:

```bash
# External drive
cp ~/backups/matrix/*.tar.gz.gpg /media/usb/

# Remote host
scp ~/backups/matrix/*.tar.gz.gpg user@remote:/backups/

# Cloud (rclone)
rclone copy ~/backups/matrix/ remote:matrix-backups/
```

### 2.6 Automate

Add to crontab (weekly):

```bash
crontab -e
```

```cron
0 4 * * 0 /home/jonathon/backup-matrix.sh >> /home/jonathon/logs/backup.log 2>&1
```

The script emails nothing — it just writes to `~/logs/backup.log`. Check that log periodically:

```bash
tail -20 ~/logs/backup.log
```

If you want email notification on failure:

```cron
0 4 * * 0 /home/jonathon/backup-matrix.sh || \
    echo "Backup failed" | mail -s "Backup Alert" you@example.com
```

---

## Part 3 — Verifying a backup

### 3.1 The one-shot integrity check

```bash
~/matrix-homeserver-stack/scripts/check-backup.sh
```

Finds the newest backup (encrypted or unencrypted) and runs all checks. Exits 0 if complete and valid, 1 if anything is wrong.

### 3.2 Manual verification

```bash
ARCHIVE=$(ls -t ~/backups/matrix/matrix-backup-*.tar.gz* | head -1)
echo "Checking: $ARCHIVE"

# 1. Checksum
cd ~/backups/matrix
sha256sum -c "$(basename "$ARCHIVE").sha256"

# 2. List contents (encrypted or not)
if [[ "$ARCHIVE" == *.gpg ]]; then
    gpg -d "$ARCHIVE" | tar -tzf -
else
    tar -tzf "$ARCHIVE"
fi
```

### 3.3 Extract and verify the database

```bash
# Extract to temp directory
TMP=$(mktemp -d)
if [[ "$ARCHIVE" == *.gpg ]]; then
    gpg -d "$ARCHIVE" | tar -xzf - -C "$TMP"
else
    tar -xzf "$ARCHIVE" -C "$TMP"
fi

# Check DB
DB=$(find "$TMP" -name 'homeserver.db' | head -1)
sqlite3 "$DB" "PRAGMA integrity_check;"
# → ok

# Check signing key
KEY=$(find "$TMP" -name '*.signing.key' | head -1)
head -1 "$KEY"
# → ed25519 a_XXXX ...

# Cleanup
rm -rf "$TMP"
```

### 3.4 Monthly verification

Once a month, do a full test-restore to a temp directory:

```bash
TMP=$(mktemp -d)
ARCHIVE=$(ls -t ~/backups/matrix/*.tar.gz.gpg | head -1)
gpg -d "$ARCHIVE" | tar -xzf - -C "$TMP"

# Verify everything
sqlite3 "$TMP"/stage-*/matrix/data/homeserver.db "PRAGMA integrity_check;"
ls "$TMP"/stage-*/matrix/data/matrix.*.signing.key
ls "$TMP"/stage-*/matrix/rtc/lk-jwt/.env

rm -rf "$TMP"
```

If it passes, the backup is valid.

---

## Part 4 — Restore procedure

### 4.1 Prerequisites on the new machine

| Requirement | How to check |
|---|---|
| Ubuntu Server 22.04/24.04 | `cat /etc/os-release` |
| Docker + Compose | `docker --version && docker compose version` |
| Caddy | `caddy version` |
| User with sudo | `sudo -v` |
| User services enabled | `loginctl show-user "$USER" \| grep Linger` |
| GPG | `gpg --version` |
| SQLite | `sqlite3 --version` |
| Same LAN IP (or plan to update router) | `hostname -I` |
| Same public IP (or plan to update DNS) | `dig +short matrix.example.com` |

### 4.2 Install dependencies (fresh machine only)

```bash
# Docker + Caddy
~/matrix-homeserver-stack/scripts/install_docker_caddy.sh

# Utilities
sudo apt install -y gpg sqlite3
```

### 4.3 Verify the backup before restoring

```bash
~/matrix-homeserver-stack/scripts/check-backup.sh ~/matrix-backup-*.tar.gz.gpg
```

**Do not proceed if this fails.** A broken backup restores a broken server. Re-download or use an older backup.

### 4.4 Decrypt and extract

```bash
mkdir -p ~/restore
cd ~/restore

gpg -d ~/matrix-backup-*.tar.gz.gpg | tar -xzf -

# Find the stage directory
STAGE=$(ls -d stage-* | head -1)
echo "Restored from: $STAGE"
```

### 4.5 Stop any existing services

If restoring over an existing install:

```bash
systemctl --user stop synapse-compose.service rtc-compose.service 2>/dev/null || true

cd ~/matrix 2>/dev/null && docker compose down 2>/dev/null || true
cd ~/matrix/rtc 2>/dev/null && docker compose down 2>/dev/null || true
```

### 4.6 Restore Synapse data

```bash
mkdir -p ~/matrix/data

# Copy with sudo (source files may be owned by UID 991)
sudo cp -a "$STAGE/matrix/data/." ~/matrix/data/

# Fix ownership — Synapse container runs as UID 991, GID 991
sudo chown -R 991:render ~/matrix/data/

# Lock down the signing key and config
sudo chmod 600 ~/matrix/data/matrix.example.com.signing.key
sudo chmod 600 ~/matrix/data/homeserver.yaml
```

**Verify:**

```bash
ls -la ~/matrix/data/ | head
# → homeserver.db, homeserver.yaml, signing.key, lk-jwt-as.yaml, media_store/

sudo sqlite3 ~/matrix/data/homeserver.db "PRAGMA integrity_check;"
# → ok
```

If the DB check fails here, the copy was corrupted. Re-extract from the archive.

### 4.7 Restore configs

```bash
# Synapse compose
mkdir -p ~/matrix
cp -a "$STAGE/matrix/docker-compose.yml" ~/matrix/

# RTC stack
mkdir -p ~/matrix/rtc
cp -a "$STAGE/matrix/rtc/." ~/matrix/rtc/

# Check ownership
ls -la ~/matrix/docker-compose.yml ~/matrix/rtc/
# → should be owned by your user, not 991 or root

# If wrong:
# chown -R "$USER:$USER" ~/matrix/docker-compose.yml ~/matrix/rtc
```

### 4.8 Restore Caddy

```bash
sudo mkdir -p /etc/caddy
sudo cp "$STAGE/etc/Caddyfile" /etc/caddy/Caddyfile
sudo chown root:root /etc/caddy/Caddyfile

# Validate
sudo caddy validate --config /etc/caddy/Caddyfile
```

**Restore Caddy certs (optional — Caddy re-issues):**

```bash
if [ -d "$STAGE/var-lib-caddy" ]; then
    sudo mkdir -p /var/lib/caddy/.local/share/caddy
    sudo cp -a "$STAGE/var-lib-caddy/." /var/lib/caddy/.local/share/caddy/
    sudo chown -R caddy:caddy /var/lib/caddy/.local/share/caddy/ 2>/dev/null || \
    sudo chown -R root:root /var/lib/caddy/.local/share/caddy/
fi

sudo systemctl reload caddy
```

### 4.9 Restore systemd units

```bash
mkdir -p ~/.config/systemd/user
cp -a "$STAGE/systemd/"*.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

**Verify:**

```bash
ls ~/.config/systemd/user/*.service
# → synapse-compose.service, rtc-compose.service
```

### 4.10 Restore user scripts

```bash
[ -f "$STAGE/home/update_domain.sh" ] && cp "$STAGE/home/update_domain.sh" ~/
[ -f "$STAGE/home/.bashrc" ] && cp "$STAGE/home/.bashrc" ~/
[ -f "$STAGE/home/.profile" ] && cp "$STAGE/home/.profile" ~/

chmod +x ~/update_domain.sh 2>/dev/null
```

### 4.11 Pull Docker images

```bash
cd ~/matrix
docker compose pull

cd ~/matrix/rtc
docker compose pull
```

### 4.12 Start services (in order)

```bash
# Synapse first (so AS registration loads)
systemctl --user enable --now synapse-compose.service
sleep 20
docker logs synapse --tail 20 | grep -iE 'application service|error'

# Then RTC
systemctl --user enable --now rtc-compose.service
sleep 15
docker logs lk-jwt --tail 15 | grep -iE 'application service|error'
docker logs livekit --tail 10 | grep -iE 'starting|turn|error'
```

Expected:

- **Synapse:** `Loaded application service: ... proxy_url: http://172.17.0.1:8081`
- **lk-jwt:** `Using application service configuration from LIVEKIT_AS_TOKEN and LIVEKIT_HS_TOKEN`
- **LiveKit:** `Starting TURN server {...}` and `starting LiveKit server {...}`

### 4.13 Verify the restore

**Containers:**

```bash
docker ps --filter name=synapse --filter name=livekit --filter name=lk-jwt \
  --format 'table {{.Names}}\t{{.Status}}'
```

All should be `Up (healthy)` or `Up`.

**Endpoints:**

```bash
# Synapse
curl -s https://matrix.example.com/_matrix/client/versions | head -c 60
# → {"versions":["r0.0.1",...

# .well-known
curl -s https://matrix.example.com/.well-known/matrix/client | python3 -m json.tool

# lk-jwt
curl -sI https://matrix.example.com/livekit/jwt/healthz | head -1
# → HTTP/2 200

# LiveKit
curl -sI https://matrix.example.com/livekit/sfu/ | head -1
# → HTTP/2 200

# Transport discovery (via Synapse, should be 401)
curl -i -s https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports | head -5
# → HTTP/2 401, server: Synapse/...
```

**Signing key unchanged:**

```bash
head -1 ~/matrix/data/matrix.example.com.signing.key
# → ed25519 a_XXXX ... (same key as before)
```

**Call test:**

1. Open Element X on iPhone, log in
2. Open Element Desktop (Flatpak), log in
3. Call between them in a group room (Element Call mode)
4. Expected: video + audio both ways

### 4.14 Cleanup

```bash
cd ~
rm -rf ~/restore
```

Keep the backup archive (don't delete it — you may need it again).

---

## Part 5 — Restore to different hardware

If the new machine has a different **LAN IP** or **public IP**:

### 5.1 LAN IP changed

Update router forwards to point at the new LAN IP. Update any hardcoded references:

```bash
# In Caddyfile (if any)
grep -r '192\.168\.50\.' /etc/caddy/Caddyfile

# In livekit.yaml
grep 'advertise_internal_ip\|node_ip' ~/matrix/rtc/livekit/livekit.yaml
```

LiveKit auto-detects its external IP via STUN. It also auto-detects the LAN IP for `advertise_internal_ip`. So if only the LAN IP changed, LiveKit picks up the new one on restart. No config change needed.

### 5.2 Public IP changed

Update DNS:

```bash
# Run the DDNS script
~/update_domain.sh

# Or manually update NameSilo
```

Restart Caddy to re-issue certs if needed:

```bash
sudo systemctl reload caddy
```

### 5.3 Domain changed

If you're restoring to a **different domain** (e.g., from `example.com` to `newdomain.com`):

```bash
# Update every reference
grep -rl 'example.com' ~/matrix/ /etc/caddy/ 2>/dev/null

# Files to edit:
# - ~/matrix/data/homeserver.yaml (server_name, public_baseurl)
# - ~/matrix/data/lk-jwt-as.yaml (id, sender_localpart, URLs)
# - ~/matrix/rtc/lk-jwt/.env (LIVEKIT_URL, LIVEKIT_FULL_ACCESS_HOMESERVERS, LIVEKIT_HS_SERVER_NAME)
# - ~/matrix/rtc/livekit/livekit.yaml (domain, webhook URL)
# - /etc/caddy/Caddyfile (all domain references)
# - ~/update_domain.sh (DOMAIN variable)
```

Then:

```bash
# New signing key for the new domain (optional — keeps old identity)
# The signing key is tied to the server_name. If server_name changes,
# Synapse generates a new key. That breaks federation for the old domain.

# Restart everything
systemctl --user restart synapse-compose.service
sleep 20
systemctl --user restart rtc-compose.service
sudo systemctl reload caddy
```

If the domain is **permanently** changing, the old signing key is useless. Generate a new one and update federation records (see `docs/FEDERATION.md`).

---

## Part 6 — Disaster recovery scenarios

### 6.1 Scenario A: Database corruption

Synapse fails to start with SQLite errors.

```bash
# Stop Synapse
systemctl --user stop synapse-compose.service

# Move the corrupted DB aside
mv ~/matrix/data/homeserver.db ~/matrix/data/homeserver.db.corrupt

# Restore from backup
ARCHIVE=$(ls -t ~/backups/matrix/matrix-backup-*.tar.gz.gpg | head -1)
gpg -d "$ARCHIVE" | tar -xzf - -C /tmp
STAGE=$(ls /tmp/stage-* | head -1)
sudo cp "$STAGE/matrix/data/homeserver.db" ~/matrix/data/
sudo chown 991:render ~/matrix/data/homeserver.db

# Clean up
rm -rf /tmp/stage-*

# Start Synapse
systemctl --user start synapse-compose.service
```

**Data loss:** messages since the last backup are gone.

### 6.2 Scenario B: Lost signing key

You deleted `matrix.example.com.signing.key` and have no backup.

**This is serious.** The signing key is your homeserver's federation identity. Without it:

- Federated servers reject your events
- Your server is treated as a new homeserver
- All federation relationships break

**Recovery:**

1. If you have a backup: restore the key file
2. If not: Synapse generates a new key on startup, but federation is broken until remote servers accept the new key
3. Post to `#synapse:matrix.org` for help with federation key rotation

**Prevention:** this is why the key is the most backed-up file. Keep it in multiple encrypted locations.

### 6.3 Scenario C: Disk failure

The Pi's SSD fails. You have a backup from last week.

```bash
# On the new Pi (or replacement SSD)
# Install Ubuntu Server

# Install dependencies
./scripts/install_docker_caddy.sh

# Restore from backup
# Follow Part 4 (steps 4.1–4.14)
```

You lose any messages/media since the last backup. Everything else is restored.

### 6.4 Scenario D: Migrate to new hardware

Same as C, but planned. New machine set up alongside the old. Restore backup to new, update DNS/router to point at new, stop old. Old can be kept as a warm standby.

---

## Part 7 — Automation

### 7.1 Automated backup (weekly)

```cron
0 4 * * 0 /home/jonathon/backup-matrix.sh >> /home/jonathon/logs/backup.log 2>&1
```

### 7.2 Automated encryption

Modify `backup-matrix.sh` to encrypt after creating the archive:

```bash
# At the end, before the integrity check:
echo "==> Encrypting archive..."
gpg --batch --yes --symmetric --cipher-algo AES256 \
    --passphrase-file "$HOME/.config/matrix-backup-passphrase" \
    "$ARCHIVE"
rm "$ARCHIVE"
ARCHIVE="$ARCHIVE.gpg"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
```

Store the passphrase file with `chmod 600`:

```bash
echo "your-backup-passphrase" > ~/.config/matrix-backup-passphrase
chmod 600 ~/.config/matrix-backup-passphrase
```

**Never commit the passphrase file to git.** It's not in the backup archive (because it's in `~/.config/`, not `~/matrix/`).

### 7.3 Automated off-site copy

```bash
# Add to the backup script or a separate cron job:
rclone copy ~/backups/matrix/ remote:matrix-backups/
```

Configure `rclone` once with your cloud provider, then it handles transfers.

### 7.4 Automated integrity verification

The backup script already runs `check-backup.sh` at the end. If the check fails, the script exits non-zero, which cron can catch.

Add email notification on failure:

```cron
0 4 * * 0 /home/jonathon/backup-matrix.sh >> /home/jonathon/logs/backup.log 2>&1 || \
    echo "Backup failed" | mail -s "Backup Alert" you@example.com
```

---

## Part 8 — Quick reference

### 8.1 Backup

```bash
~/backup-matrix.sh
# → creates ~/backups/matrix/matrix-backup-YYYYMMDD-HHMMSS.tar.gz
# → verifies integrity automatically
# → exits 0 if valid, 1 if failed
```

### 8.2 Verify

```bash
~/matrix-homeserver-stack/scripts/check-backup.sh
# → runs all checks on the newest backup
# → exits 0 if valid, 1 if failed
```

### 8.3 Encrypt

```bash
cd ~/backups/matrix
gpg --symmetric --cipher-algo AES256 matrix-backup-*.tar.gz
rm matrix-backup-*.tar.gz
sha256sum matrix-backup-*.tar.gz.gpg > matrix-backup-*.tar.gz.gpg.sha256
```

### 8.4 Restore (one-liner sequence)

```bash
# 1. Verify
~/matrix-homeserver-stack/scripts/check-backup.sh ~/matrix-backup-*.tar.gz.gpg

# 2. Extract
mkdir -p ~/restore && cd ~/restore
gpg -d ~/matrix-backup-*.tar.gz.gpg | tar -xzf -
STAGE=$(ls -d stage-* | head -1)

# 3. Stop services
systemctl --user stop synapse-compose.service rtc-compose.service 2>/dev/null || true

# 4. Restore data
mkdir -p ~/matrix/data ~/matrix/rtc ~/.config/systemd/user /etc/caddy
sudo cp -a "$STAGE/matrix/data/." ~/matrix/data/
sudo chown -R 991:render ~/matrix/data/
sudo chmod 600 ~/matrix/data/*.signing.key
cp -a "$STAGE/matrix/docker-compose.yml" ~/matrix/
cp -a "$STAGE/matrix/rtc/." ~/matrix/rtc/
sudo cp "$STAGE/etc/Caddyfile" /etc/caddy/
cp -a "$STAGE/systemd/"*.service ~/.config/systemd/user/

# 5. Start
systemctl --user daemon-reload
systemctl --user enable --now synapse-compose.service
sleep 20
systemctl --user enable --now rtc-compose.service
sleep 15

# 6. Verify
curl -s https://matrix.example.com/_matrix/client/versions | head -c 60
curl -sI https://matrix.example.com/livekit/jwt/healthz | head -1
```

### 8.5 Emergency checklist

| Symptom | Check | Fix |
|---|---|---|
| Synapse won't start | `docker logs synapse` | DB corruption? Restore from backup |
| Caddy 502 | `docker ps` — Synapse running? | Restart Synapse |
| Calls fail | `docker logs lk-jwt`, `docker logs livekit` | Check AS mode, keys, TURN |
| Federation broken | `head -1 ~/matrix/data/*.signing.key` | Restore signing key from backup |
| "server id error" | `curl -i https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` | Should be `401` with `server: Synapse` |

---

## See also

- [`INSTALL.md`](INSTALL.md) — installation walkthrough
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — components and data flow
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures
- [`../scripts/backup-matrix.sh`](../scripts/backup-matrix.sh) — backup script
- [`../scripts/check-backup.sh`](../scripts/check-backup.sh) — integrity check script
