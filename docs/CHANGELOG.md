# Changelog

All notable changes to this stack are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-11-03

Initial release. First version to be committed to the public repository.

### Added — Stack components

- **Synapse** homeserver (Docker Compose, SQLite backend, SQLite snapshot backup)
- **LiveKit** SFU with embedded TURN server for MatrixRTC media routing
- **lk-jwt-service** in Application Service (AS) mode
  - Room membership verification via MSC4502
  - AS proxy path via MSC4512 (`/_matrix/client/unstable/io.element.msc4195/rtc/livekit/*`)
  - Webhook receiver for MSC4140 delegated delayed leave
- **Caddy** reverse proxy with automatic Let's Encrypt certificates
- **MatrixRTC transport discovery** served natively by Synapse (MSC4143)
  - `matrix_rtc.transports` in `homeserver.yaml`
  - No static Caddy handler for `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` (this was the critical fix for cross-client calls)

### Added — Configuration templates

- `caddy/Caddyfile.example` — reverse proxy for Matrix, LiveKit, lk-jwt
- `synapse/docker-compose.yml` — ready to use, no edits needed
- `synapse/homeserver.yaml.example` — Synapse config template with placeholders
- `synapse/lk-jwt-as.yaml.example` — Application Service registration template
- `rtc/docker-compose.yml` — LiveKit + lk-jwt compose, ready to use
- `rtc/livekit/livekit.yaml.example` — LiveKit config with embedded TURN, codec restrictions, webhook
- `rtc/lk-jwt/.env.example` — lk-jwt environment template

### Added — Systemd units

- `systemd/synapse-compose.service` — Synapse systemd user service (`Type=oneshot`)
- `systemd/rtc-compose.service` — LiveKit + lk-jwt systemd user service (`Type=oneshot`)

### Added — Scripts

- `scripts/install_docker_caddy.sh` — installs Docker CE, Compose plugin, Caddy
- `scripts/update_domain.sh` — NameSilo DDNS updater (optimized: one API call per run)
- `scripts/update_matrix_images.sh` — pulls latest images, restarts only changed containers, emails report
- `scripts/backup-matrix.sh` — full backup with integrity verification
- `scripts/check-backup.sh` — backup integrity checker (checksum, DB, signing key)

### Added — Documentation

- `README.md` — overview, quick start, documentation index, repository layout
- `docs/DNS-ROUTER-CONFIGURATION.md` — NameSilo DNS, router forwards, UFW, Docker+Caddy install
- `docs/INSTALL.md` — full installation walkthrough
- `docs/CONFIGURATION.md` — every config file and option explained
- `docs/ARCHITECTURE.md` — components, data flow, port map, design decisions, glossary
- `docs/PORTS-AND-FIREWALL.md` — full port reference, router forwards, UFW setup
- `docs/DOCKER-COMMANDS.md` — common Docker commands for managing containers
- `docs/BACKUP-RESTORE.md` — backup, integrity checks, and restore procedures
- `docs/TROUBLESHOOTING.md` — common failures and how to fix them
- `docs/FEDERATION.md` — optional federation setup
- `docs/CHANGELOG.md` — this file
- `examples/router-forwards.md` — quick checklist for port forwards

### Added — Project files

- `LICENSE` — AGPL-3.0
- `.gitignore` — excludes secrets, data, backups, rollback tags

### Verified working

**Client compatibility:**

- ✅ Element X (iPhone) ↔ Element X (iPhone) video calls
- ✅ Element Desktop/Flatpak ↔ Element Desktop/Flatpak video calls
- ✅ Element X (iPhone) ↔ Element Desktop/Flatpak video calls

**Media quality:**

- ✅ Audio and video both directions
- ✅ VP8 simulcast with 3 spatial layers (320×180, 640×360, 1280×720)
- ✅ H264 fallback for hardware-accelerated encoding on Apple devices

**Infrastructure:**

- ✅ AS mode with room membership verification via Synapse
- ✅ LiveKit embedded TURN for NAT traversal
- ✅ `advertise_internal_ip: true` to avoid NAT hairpin for LAN clients
- ✅ Transport discovery served by Synapse with authentication
- ✅ MatrixRTC call lifecycle (create room → join → leave → cleanup)
- ✅ Delegated delayed leave (via webhook + sanity check fallback)
- ✅ Federation-ready (signing key, `.well-known` for both client and server discovery)
- ✅ Automatic TLS via Caddy (Let's Encrypt)
- ✅ Reboot-safe (systemd user services with lingering enabled)

**Backup and restore:**

- ✅ Full backup script with integrity verification
- ✅ Restore procedure tested (SQLite integrity check passes, signing key preserved)
- ✅ Encrypted backup support (GPG AES256)

### Design decisions

- **No coturn** — legacy 1:1 calling is deprecated and can't reach Element X. LiveKit's embedded TURN handles MatrixRTC relay. Frees ~22 router rules.
- **VP8 + H264 + Opus codecs only** — VP9 and AV1 trigger `dependencyDescriptorExtID mismatch` across mixed client SDKs (Rust ↔ JS). See `docs/TROUBLESHOOTING.md` §3.2.
- **No static Caddy handler for `/rtc/transports`** — the endpoint must be served by Synapse with authentication. A static response breaks cross-client calls (a subtle bug discovered during testing). See `docs/ARCHITECTURE.md` §"Why no static Caddy handler".
- **`advertise_internal_ip: true`** — LAN clients get the LAN IP in ICE candidates, avoiding NAT hairpin. See `docs/ARCHITECTURE.md`.
- **`Type=oneshot` systemd units** — manual container restarts work without fighting systemd. See `docs/ARCHITECTURE.md`.
- **Single-host deployment** — designed for a Raspberry Pi 5 (8GB) or small x86_64 host. Multi-node (HA) not supported.

### Known limitations

- **`delegate_delayed_leave` 401 errors** in lk-jwt logs
  - Cosmetic client-side bug — Element X and Flatpak send an empty body to this endpoint
  - Calls work; the MSC4140 "clean leave on disconnect" doesn't fire
  - Workaround: enable `LIVEKIT_SANITY_CHECK_INTERVAL_SECONDS=30` in `lk-jwt/.env` for pull-based stale participant cleanup
  - Awaiting client-side fixes from Element

- **VP9 and AV1 excluded from `enabled_codecs`**
  - They trigger `dependencyDescriptorExtID mismatch` on LiveKit 1.13.11 with mixed client SDKs
  - VP8 + H264 + Opus is the verified-working set
  - If a future LiveKit version fixes the extension ID negotiation, VP9/AV1 can be re-enabled

- **Legacy 1:1 calling not supported**
  - Element is deprecating it (`m.call.*`)
  - Element X (iPhone/Android) dropped legacy support entirely
  - In a mixed iPhone + desktop environment, legacy calls are useless
  - Only MatrixRTC (Element Call) works for cross-client calls

- **`Element X ↔ Element Desktop` works via a shared LiveKit client SDK**
  - Both clients use `livekit-client` JS 2.22.3 (Element X runs it in WKWebView, Element Desktop in Electron)
  - The Matrix SDKs differ (Rust vs JS), but that only affects signaling, not media
  - Transport discovery via Synapse handles the signaling gap
  - If a future Element X update changes the LiveKit client version independently, cross-client calls may regress

### Dependencies

Verified working with:

- Ubuntu Server 22.04 / 24.04 LTS
- Raspberry Pi 5 (ARM64, 8GB RAM, NVMe SSD)
- Docker CE 27.x + Docker Compose plugin 2.x
- Caddy 2.11.7
- Synapse 1.164.1
- lk-jwt-service 0.9.0
- LiveKit 1.13.11

### Upgrade notes

N/A — first release.

### Migration notes

N/A — first release.

---

## Unreleased

Changes that will be in the next release will be listed here.

### Planned

- **`docs/FEDERATION.md`** — optional federation setup guide
- **`docs/CONFIGURATION.md`** — every config file explained (in progress)
- **Better push notification support** — if self-hosted sygnal is added
- **Expand TURN relay range** — if user needs 10+ person calls
- **Upgrade to newer LiveKit** — if `dependencyDescriptorExtID` is fixed upstream, re-enable VP9/AV1
- **Optional static site hosting** — documented pattern for hosting a static site via Caddy alongside the Matrix stack

---

## Version history summary

| Version | Date | Highlights |
|---|---|---|
| 1.0.0 | 2026-11-03 | Initial release — full Matrix + MatrixRTC stack |

---

## See also

- [`README.md`](../README.md) — project overview and documentation index
- [`INSTALL.md`](INSTALL.md) — installation walkthrough
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — component design and decisions
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures
- [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md) — backup and restore
