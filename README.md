# matrix-homeserver-stack

A complete, deployable self-hosted Matrix homeserver with MatrixRTC voice/video calling, designed for small-scale personal deployments. Runs Synapse, LiveKit, lk-jwt, and Caddy behind a reverse proxy with automatic Let's Encrypt certificates.

**Verified working on:** Ubuntu Server 22.04/24.04 LTS, Raspberry Pi 5 (ARM64), November 2026.

**Stack versions at time of writing:** Synapse 1.164.1, lk-jwt-service 0.9.0, LiveKit 1.13.11, Caddy 2.11.7.

---

## What this stack provides

- **Matrix homeserver** (Synapse) with federation ready
- **MatrixRTC voice/video** via LiveKit (Element Call, MSC4143/4195)
- **All client pairs work:** Element X ↔ Element X (iPhone), Element Desktop/Flatpak ↔ Element Desktop/Flatpak, and Element X ↔ Element Desktop
- **TURN/NAT traversal** via LiveKit's embedded TURN server
- **Automatic TLS** via Caddy (Let's Encrypt)
- **Systemd user services** for reboot-safe operation
- **Backup and integrity-check scripts**
- **Documented troubleshooting** for the common failure modes

---

## What this stack does NOT provide

- **Legacy 1:1 calling** (`m.call.*`) — removed. Element is deprecating it, and it can't reach Element X clients. Only MatrixRTC (Element Call) is supported.
- **Multi-node deployment** — designed for a single host. For HA, use Synapse's worker architecture and a shared Postgres.
- **Automated provisioning** — files are templates. You edit placeholders, follow the install guide, and deploy.
- **Push notification gateway** — uses matrix.org's push gateway (the default). Self-hosted sygnal is out of scope.

---

## Architecture at a glance

```text
Client (Element X / Element Desktop / Element Web)
   │
   │ HTTPS (443)
   ▼
┌──────────────────────────────────────────────────────┐
│ Caddy                                                 │
│   .well-known/matrix/*       → static JSON           │
│   /_matrix/client/*          → Synapse (8008)        │
│   /_matrix/federation/*      → Synapse (8008)        │
│   /_synapse/*                → Synapse (8008)        │
│   /livekit/jwt/*             → lk-jwt (8081)         │
│   /livekit/sfu/*             → LiveKit (7880)        │
└──────────────────────────────────────────────────────┘
                    │
      ┌─────────────┼─────────────┐
      ▼             ▼             ▼
   Synapse       lk-jwt        LiveKit
   (8008)        (8081)        (7880, 7881)
                    │             │
                    └────────────►│
                                  ▼
                          Media + TURN
                          (UDP 50000-50020, 3479, 50300-50310)
```

**Full architecture, component roles, data flow, port map, and design decisions:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

---

## Prerequisites

- **Hardware:** Raspberry Pi 5 (8GB recommended) or any x86_64/ARM64 Linux host with 4GB+ RAM
- **OS:** Ubuntu Server 22.04/24.04 LTS
- **Software:** Docker + Docker Compose plugin, Caddy
- **Network:** public IP (or DDNS), domain with DNS control, router with 64+ port-forward rules
- **Accounts:** Let's Encrypt (via Caddy, automatic) and optionally matrix.org for federation

**Router port forwards required:**

- `80`, `443` (TCP) — Caddy
- `3479` (UDP) — LiveKit embedded TURN
- `7881` (TCP) — LiveKit TCP fallback
- `50000–50020` (UDP) — LiveKit media
- `50300–50310` (UDP) — LiveKit TURN relay

See [`examples/router-forwards.md`](examples/router-forwards.md) and [`docs/PORTS-AND-FIREWALL.md`](docs/PORTS-AND-FIREWALL.md) for the full checklist.

---

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/jonathonp3/matrix-homeserver-stack.git
cd matrix-homeserver-stack

# 2. Read the DNS, router, and install guide
cat docs/DNS-ROUTER-CONFIGURATION.md

# 3. Install Docker and Caddy
chmod +x scripts/install_docker_caddy.sh
./scripts/install_docker_caddy.sh
# Log out and back in for docker group

# 4. Follow the full installation guide
cat docs/INSTALL.md

# 5. Replace placeholders:
#    - matrix.example.com → your domain
#    - jonathon           → your Linux username
#    - <PLACEHOLDER>      → generated secrets

# 6. Verify
curl -s https://matrix.example.com/_matrix/client/versions | head -c 60
# → {"versions":["r0.0.1",...

# 7. Test a call
# Open Element X on iPhone, Element Desktop on PC
# Call between them in a group room (Element Call mode)
```

---

## Documentation

| Document | What it covers |
|---|---|
| [`docs/DNS-ROUTER-CONFIGURATION.md`](docs/DNS-ROUTER-CONFIGURATION.md) | NameSilo DNS, router forwards, UFW, Docker+Caddy install |
| [`docs/INSTALL.md`](docs/INSTALL.md) | Full installation walkthrough (step by step) |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | Every configuration file and option explained |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Components, data flow, port map, design decisions, glossary |
| [`docs/PORTS-AND-FIREWALL.md`](docs/PORTS-AND-FIREWALL.md) | Full port reference, router forwards, UFW setup |
| [`docs/DOCKER-COMMANDS.md`](docs/DOCKER-COMMANDS.md) | Common Docker commands for managing containers |
| [`docs/BACKUP-RESTORE.md`](docs/BACKUP-RESTORE.md) | Backup, integrity checks, and restore procedures |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Common failures and how to fix them |
| [`docs/FEDERATION.md`](docs/FEDERATION.md) | Optional federation setup |
| [`docs/CHANGELOG.md`](docs/CHANGELOG.md) | Version history |

---

---

## Repository layout

```text
matrix-homeserver-stack/
├── README.md                             ← this file
├── LICENSE                               ← AGPL-3.0
├── .gitignore                            ← excludes secrets, data, backups
│
├── caddy/
│   └── Caddyfile.example                 ← reverse proxy template
│
├── synapse/
│   ├── docker-compose.yml                ← Synapse compose (ready to use)
│   ├── homeserver.yaml.example           ← Synapse config template
│   └── lk-jwt-as.yaml.example            ← AS registration template
│
├── rtc/
│   ├── docker-compose.yml                ← LiveKit + lk-jwt compose (ready to use)
│   ├── livekit/
│   │   └── livekit.yaml.example          ← LiveKit config template
│   └── lk-jwt/
│       └── .env.example                  ← lk-jwt env template
│
├── systemd/
│   ├── synapse-compose.service           ← Synapse systemd unit
│   └── rtc-compose.service               ← RTC systemd unit
│
├── scripts/
│   ├── install_docker_caddy.sh           ← Docker + Caddy installer
│   ├── update_domain.sh                  ← NameSilo DDNS updater
│   ├── update_matrix_images.sh           ← Container image updater
│   ├── backup-matrix.sh                  ← Backup script
│   └── check-backup.sh                   ← Backup integrity checker
│
├── docs/
│   ├── DNS-ROUTER-CONFIGURATION.md
│   ├── INSTALL.md
│   ├── CONFIGURATION.md
│   ├── ARCHITECTURE.md
│   ├── PORTS-AND-FIREWALL.md
│   ├── DOCKER-COMMANDS.md
│   ├── BACKUP-RESTORE.md
│   ├── TROUBLESHOOTING.md
│   ├── FEDERATION.md
│   └── CHANGELOG.md
│
└── examples/
    └── router-forwards.md                ← quick port-forward checklist
```

---

## Configuration templates

The repo uses `.example` suffix for files that need redaction or placeholder replacement. Real files go in `.gitignore`.

| Template | Copy to | Edit |
|---|---|---|
| `caddy/Caddyfile.example` | `/etc/caddy/Caddyfile` | Replace `matrix.example.com` and `example.com` |
| `synapse/docker-compose.yml` | `~/matrix/docker-compose.yml` | Replace `matrix.example.com` |
| `synapse/homeserver.yaml.example` | `~/matrix/data/homeserver.yaml` | Replace placeholders (see comments) |
| `synapse/lk-jwt-as.yaml.example` | `~/matrix/data/lk-jwt-as.yaml` | Generate AS/HS tokens |
| `rtc/docker-compose.yml` | `~/matrix/rtc/docker-compose.yml` | No edit needed |
| `rtc/livekit/livekit.yaml.example` | `~/matrix/rtc/livekit/livekit.yaml` | Replace domain + API key/secret |
| `rtc/lk-jwt/.env.example` | `~/matrix/rtc/lk-jwt/.env` | Replace domain + API key/secret + AS/HS tokens |
| `systemd/*.service` | `~/.config/systemd/user/` | Replace `jonathon` with your username |

**Never commit real config files** — they contain secrets. The `.gitignore` excludes them.

---

## Scripts

| Script | Purpose | Run as |
|---|---|---|
| `scripts/install_docker_caddy.sh` | Installs Docker CE + Compose plugin + Caddy | `sudo ./scripts/install_docker_caddy.sh` |
| `scripts/update_domain.sh` | Updates NameSilo A records to current public IP | Cron (every 15 min) |
| `scripts/update_matrix_images.sh` | Pulls latest container images, restarts if changed, emails report | Cron (weekly) |
| `scripts/backup-matrix.sh` | Creates a full backup, verifies integrity, exits non-zero on failure | Cron (weekly) |
| `scripts/check-backup.sh` | Verifies a backup archive (checksum, DB integrity, signing key) | Manual or from backup script |

All scripts use `set -euo pipefail` and are safe to re-run.

---

## The most important file: signing key

`matrix/data/matrix.<yourdomain>.signing.key` is your homeserver's identity.

**What is federation?** Matrix servers talk to each other so users on different servers can message each other. When your server sends an event to another server, it signs it with this key. The receiving server verifies the signature against your public key to confirm the event actually came from you (and wasn't tampered with).

**Why losing it is bad:** without the original key, your server generates a new identity. Federated servers see events signed by an unrecognized key and reject them. In practice, recovering federation after a key change requires manual intervention from every server you federate with — and most don't bother. Your server is effectively cut off from the fediverse.

**Do you need to care?** If your server is personal (just you and your family, no users on other homeservers), federation never happens, and losing the key just means clients need to re-verify. If your server federates with matrix.org or other homeservers, losing the key is catastrophic.

**Back it up in multiple places. Never commit it to git.** The `.gitignore` in this repo excludes it.

See [`docs/FEDERATION.md`](docs/FEDERATION.md) for more on federation.

---

## Design decisions

Why the stack looks the way it does:

- **No coturn** — legacy 1:1 calling is deprecated and can't reach Element X. LiveKit's embedded TURN handles MatrixRTC relay. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#why-no-coturn).
- **VP8 + H264 + Opus codecs** — VP9/AV1 trigger `dependencyDescriptorExtID mismatch` across client SDKs. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#why-vp8--h264--opus-no-vp9av1).
- **No static Caddy handler for `/rtc/transports`** — the endpoint must be served by Synapse with authentication. A static response breaks cross-client calls. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#why-no-static-caddy-handler-for-rtctransports).
- **`advertise_internal_ip: true`** — LAN clients get the LAN IP in ICE candidates, avoiding NAT hairpin. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#why-advertise_internal_ip-true-on-livekit).
- **`Type=oneshot` systemd units** — manual container restarts work without fighting systemd. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#why-typeoneshot-for-systemd-units).

---

## Known limitations

1. **`delegate_delayed_leave` 401 errors** in lk-jwt logs — cosmetic client-side bug (Element X / Flatpak send empty body). Calls work; the MSC4140 "clean leave on disconnect" doesn't. Awaiting client updates.

2. **VP9 and AV1 excluded from `enabled_codecs`** — they trigger `dependencyDescriptorExtID mismatch` on LiveKit 1.13.11 with mixed client SDKs. VP8 + H264 + Opus is the verified-working set.

3. **Element X ↔ Element Desktop works because both use the same LiveKit client SDK** (JS 2.22.3). The Matrix SDKs differ (Rust vs JS), but that only affects signaling, not media — and transport discovery via Synapse handles it.

4. **Legacy 1:1 calling not supported** — Element is deprecating it, and it can't reach Element X clients. Only MatrixRTC (Element Call) works for cross-client calls.

---

## Contributing

Issues and PRs welcome. This repo is a template, not a maintained application — but improvements to the docs and configs are appreciated.

If you're reporting a problem, include:

- `docker ps` output
- Relevant logs (`docker logs --tail 50 <container>`)
- The relevant config file (redact secrets)
- What you've already tried

---

## License

AGPL-3.0 — matches Synapse, LiveKit, and Element's licenses. See [LICENSE](LICENSE).

---

## Acknowledgments

Built by debugging a real deployment over many days. The troubleshooting doc captures failures and fixes that others will likely encounter. Special thanks to the Matrix, Element, and LiveKit communities for the support, documentation, and bug reports that made this possible.
