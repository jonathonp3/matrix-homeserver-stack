# Installation

Full installation walkthrough for `matrix-homeserver-stack`, from fresh Ubuntu Server to a working Matrix homeserver with voice/video calling.

**Estimated time:** 1–2 hours (mostly waiting for DNS propagation and Let's Encrypt certs).

**Prerequisites:** Ubuntu Server 22.04/24.04 LTS, domain with DNS control, public IP, router with port-forward access.

---

## Overview

The installation has 7 phases:

1. **DNS** — point `matrix.example.com` and `example.com` at your public IP
2. **Router** — forward 80, 443, and LiveKit UDP ports to the Pi
3. **Firewall** — open the same ports in UFW on the Pi
4. **Dependencies** — install Docker, Compose, and Caddy
5. **Synapse** — deploy the homeserver
6. **MatrixRTC** — deploy LiveKit, lk-jwt, and the AS registration
7. **Verify** — test the API, then test a call

See [`DNS-ROUTER-CONFIGURATION.md`](DNS-ROUTER-CONFIGURATION.md) for phases 1–4 (DNS, router, UFW, Docker+Caddy install), and [`PORTS-AND-FIREWALL.md`](PORTS-AND-FIREWALL.md) for the full port reference.

This doc covers phases 5–7.

---

## Phase 5 — Deploy Synapse

### 5.1 Create the directory structure

```bash
mkdir -p ~/matrix/{data,rtc/livekit,rtc/lk-jwt}
cd ~/matrix
```

### 5.2 Generate the Synapse config

```bash
docker run -it --rm \
  -v "$PWD/data:/data" \
  -e SYNAPSE_SERVER_NAME=matrix.example.com \
  -e SYNAPSE_REPORT_STATS=no \
  ghcr.io/element-hq/synapse:latest generate
```

This creates:

- `~/matrix/data/homeserver.yaml`
- `~/matrix/data/matrix.example.com.log.config`
- `~/matrix/data/matrix.example.com.signing.key`

**⚠️ The signing key is your homeserver identity. Back it up immediately.** See [BACKUP-RESTORE.md](BACKUP-RESTORE.md).

### 5.3 Edit `homeserver.yaml`

```bash
sudo nano ~/matrix/data/homeserver.yaml
```

Ensure these settings are present (add them if missing):

```yaml
server_name: "matrix.example.com"
public_baseurl: "https://matrix.example.com/"

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

experimental_features:
  msc3266_enabled: true
  msc4222_enabled: true
  msc4140_enabled: true
  msc4143_enabled: true
  msc4502_enabled: true
  msc4512_enabled: true

matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: https://matrix.example.com/livekit/jwt
```

**Do NOT add** `livekit_jwt_sso:` — it's not a recognized Synapse config key and does nothing.

Validate the YAML:

```bash
sudo python3 -c "import yaml; yaml.safe_load(open('/home/jonathon/matrix/data/homeserver.yaml'))" && echo "✓ Valid"
```

### 5.4 Create the Synapse compose file

Copy the template:

```bash
cp ~/matrix-homeserver-stack/synapse/docker-compose.yml ~/matrix/docker-compose.yml
```

Edit it to replace `matrix.example.com` with your domain:

```bash
nano ~/matrix/docker-compose.yml
```

Verify:

```bash
cat ~/matrix/docker-compose.yml
```

### 5.5 Start Synapse

```bash
cd ~/matrix
docker compose up -d
docker logs -f synapse
```

Wait for `Synapse now listening on TCP port 8008`. Press `Ctrl+C`.

Verify:

```bash
curl -s http://127.0.0.1:8008/_matrix/client/versions | head -c 60
```

### 5.6 Configure Caddy

Copy the Caddyfile template:

```bash
sudo cp ~/matrix-homeserver-stack/caddy/Caddyfile.example /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile
```

Replace `matrix.example.com` and `example.com` with your real domain.

Validate and reload:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Verify from outside:

```bash
curl -sI https://matrix.example.com/_matrix/client/versions | head -1
# → HTTP/2 200
```

---

## Phase 6 — Deploy MatrixRTC

### 6.1 Generate LiveKit and lk-jwt secrets

```bash
LIVEKIT_API_KEY=$(openssl rand -hex 8)
LIVEKIT_API_SECRET=$(openssl rand -hex 32)
AS_TOKEN=$(openssl rand -hex 32)
HS_TOKEN=$(openssl rand -hex 32)

cat > /tmp/matrix-secrets.txt <<EOF
LIVEKIT_API_KEY=$LIVEKIT_API_KEY
LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET
AS_TOKEN=$AS_TOKEN
HS_TOKEN=$HS_TOKEN
EOF

cat /tmp/matrix-secrets.txt
```

**Save this file somewhere safe.** You'll need these values repeatedly.

### 6.2 Deploy LiveKit

Copy the template:

```bash
cp ~/matrix-homeserver-stack/rtc/livekit/livekit.yaml.example ~/matrix/rtc/livekit/livekit.yaml
nano ~/matrix/rtc/livekit/livekit.yaml
```

Replace:

- `matrix.example.com` → your domain
- `<LIVEKIT_API_KEY>` and `<LIVEKIT_API_SECRET>` → the values from 6.1

Also update `webhook.api_key` to the API key.

Validate:

```bash
python3 -c "import yaml; yaml.safe_load(open('/home/jonathon/matrix/rtc/livekit/livekit.yaml'))" && echo "✓ Valid"
```

### 6.3 Deploy lk-jwt

Copy the template:

```bash
cp ~/matrix-homeserver-stack/rtc/lk-jwt/.env.example ~/matrix/rtc/lk-jwt/.env
nano ~/matrix/rtc/lk-jwt/.env
```

Replace:

- `matrix.example.com` → your domain
- `<LIVEKIT_API_KEY>` and `<LIVEKIT_API_SECRET>` → from 6.1
- `<LIVEKIT_AS_TOKEN>` and `<LIVEKIT_HS_TOKEN>` → from 6.1

### 6.4 Deploy the AS registration

Copy the template:

```bash
sudo cp ~/matrix-homeserver-stack/synapse/lk-jwt-as.yaml.example ~/matrix/data/lk-jwt-as.yaml
sudo nano ~/matrix/data/lk-jwt-as.yaml
```

Replace:

- `<LIVEKIT_AS_TOKEN>` and `<LIVEKIT_HS_TOKEN>` → from 6.1

Verify they match `~/matrix/rtc/lk-jwt/.env`:

```bash
grep -E 'AS_TOKEN|HS_TOKEN' ~/matrix/rtc/lk-jwt/.env
sudo grep -E 'as_token|hs_token' ~/matrix/data/lk-jwt-as.yaml
```

The values must be identical.

### 6.5 Add the AS registration to Synapse

```bash
sudo nano ~/matrix/data/homeserver.yaml
```

Add:

```yaml
app_service_config_files:
  - /data/lk-jwt-as.yaml
```

Validate:

```bash
sudo python3 -c "import yaml; yaml.safe_load(open('/home/jonathon/matrix/data/homeserver.yaml'))" && echo "✓ Valid"
```

### 6.6 Deploy the RTC compose file

Copy the template:

```bash
cp ~/matrix-homeserver-stack/rtc/docker-compose.yml ~/matrix/rtc/docker-compose.yml
```

No edits needed (all config is in the mounted files).

### 6.7 Start the RTC stack

```bash
cd ~/matrix/rtc
docker compose up -d
sleep 10

# Check lk-jwt
docker logs lk-jwt --tail 15 | grep -iE 'application service|error|Starting'

# Check LiveKit
docker logs livekit --tail 10 | grep -iE 'starting|turn|error'
```

Expected:

- **lk-jwt:** `Using application service configuration from LIVEKIT_AS_TOKEN and LIVEKIT_HS_TOKEN` (no "deprecated" warning)
- **LiveKit:** `Starting TURN server {...}` and `starting LiveKit server {...}`

### 6.8 Restart Synapse to load the AS registration

```bash
cd ~/matrix
docker compose restart synapse
sleep 20

docker logs synapse --tail 20 | grep -iE 'application service'
# → Loaded application service: ... proxy_url: http://172.17.0.1:8081
```

### 6.9 Install systemd units

```bash
cp ~/matrix-homeserver-stack/systemd/synapse-compose.service ~/.config/systemd/user/
cp ~/matrix-homeserver-stack/systemd/rtc-compose.service ~/.config/systemd/user/

# Edit to replace `jonathon` with your username (if different)
nano ~/.config/systemd/user/synapse-compose.service
nano ~/.config/systemd/user/rtc-compose.service

systemctl --user daemon-reload
systemctl --user enable --now synapse-compose.service
sleep 20
systemctl --user enable --now rtc-compose.service
```

### 6.10 Enable lingering (reboot-safe)

```bash
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" | grep Linger
# → Linger=yes
```

---

## Phase 7 — Verify

### 7.1 Containers running

```bash
docker ps --filter name=synapse --filter name=livekit --filter name=lk-jwt \
  --format 'table {{.Names}}\t{{.Status}}'
```

Expected: all `Up` (or `Up (healthy)`).

### 7.2 Endpoints

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

# Transport discovery (must be 401, not 200)
curl -i -s https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports | head -5
# → HTTP/2 401, server: Synapse/...
```

### 7.3 Create the first user

```bash
docker exec -it synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  -u yourusername -a \
  http://localhost:8008
```

Prompts for a password. Save it.

### 7.4 Test with Element

1. Open Element X on iPhone (or Element Desktop)
2. Log in with `@yourusername:matrix.example.com` and the password
3. Verify sync works (messages appear)

### 7.5 Test a call

1. Create a **group room** (not a DM) with a second user
2. Start a **video call** in Element Call mode
3. Expected: video + audio both directions

If it works, **the installation is complete.**

---

## Next steps

- **Backup:** [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md) — set up automated backups immediately
- **Troubleshooting:** [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — if anything fails
- **Federation:** [`FEDERATION.md`](FEDERATION.md) — if you want to federate with other homeservers

---

## See also

- [`DNS-ROUTER-CONFIGURATION.md`](DNS-ROUTER-CONFIGURATION.md) — DNS, router, UFW, Docker+Caddy install
- [`CONFIGURATION.md`](CONFIGURATION.md) — every config option explained
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — component design
- [`PORTS-AND-FIREWALL.md`](PORTS-AND-FIREWALL.md) — port reference
- [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md) — backup and restore
