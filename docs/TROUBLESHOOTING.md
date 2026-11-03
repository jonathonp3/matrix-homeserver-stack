# Troubleshooting

Common failures and how to fix them. Organized by symptom.

**Before you start:** most issues are visible in the logs. Run these first:

```bash
docker ps
docker logs --tail 50 synapse
docker logs --tail 50 livekit
docker logs --tail 50 lk-jwt
```

---

## Part 1 — Installation and startup

### 1.1 Synapse won't start

```bash
docker logs synapse --tail 50
```

Common causes and fixes:

| Error | Cause | Fix |
|---|---|---|
| `Permission denied` on `homeserver.db` | Wrong file ownership | `sudo chown -R 991:render ~/matrix/data/` |
| `database disk image is malformed` | DB corruption | Restore from backup (see [BACKUP-RESTORE.md](BACKUP-RESTORE.md)) |
| `Could not parse config` | YAML syntax error | `sudo python3 -c "import yaml; yaml.safe_load(open('/home/jonathon/matrix/data/homeserver.yaml'))"` |
| `app_service_config_files` file not found | AS registration missing | Check `ls ~/matrix/data/lk-jwt-as.yaml` |
| `Cannot listen on 0.0.0.0:8008` | Port already in use | `sudo ss -tlnp \| grep 8008` — another process is on 8008 |
| `FATAL: role "synapse" does not exist` | Wrong DB config (Postgres) | For SQLite, check `database.name: sqlite3` in `homeserver.yaml` |

### 1.2 Caddy returns 502 on all paths

502 means Caddy is running but the backend is unreachable.

```bash
sudo systemctl status caddy
docker ps --filter name=synapse
```

If Caddy is up and Synapse is up, the issue is usually:

- Caddy's `reverse_proxy 127.0.0.1:8008` is correct, but Synapse isn't listening on 8008
- Check: `sudo ss -tlnp | grep 8008` — should show `127.0.0.1:8008`
- If nothing is listening, restart Synapse: `systemctl --user restart synapse-compose.service`

### 1.3 Caddy won't start (certificate errors)

```bash
sudo journalctl -u caddy -n 50
```

| Error | Cause | Fix |
|---|---|---|
| `no valid A records found` | DNS not pointing at public IP | `dig +short matrix.example.com` — should be your public IP |
| `rateLimited` | Too many cert requests | Wait 1 hour, or use staging CA to test first |
| `connection refused` on :80 | Port 80 not forwarded, or blocked by UFW | Check router forwards + `sudo ufw status` |

Caddy retries cert requests every few minutes, so if DNS was just updated, wait 5–10 minutes before assuming it's broken.

### 1.4 Docker permission denied

```bash
docker ps
# → permission denied while trying to connect to the Docker daemon socket
```

Your user isn't in the `docker` group.

```bash
sudo usermod -aG docker "$USER"
# Log out and back in
# Verify
groups | grep docker
```

### 1.5 "Failed to listen on 0.0.0.0:8008"

This appears in Synapse logs during a restart:

```text
WARNING - call_when_running - Failed to listen on 0.0.0.0, continuing because listening on [::]
```

It's a transient warning — the new container starts before the old one fully releases port 8008. Synapse falls back to IPv6 `[::]`, which still serves `127.0.0.1:8008` via Docker's port mapping. Requests still work.

**If it persists** (Synapse never binds 8008):

```bash
docker ps -a | grep synapse
# → two containers named synapse? That's the issue.

# Stop both, remove the stale one
docker stop synapse
docker rm synapse
systemctl --user restart synapse-compose.service
```

---

## Part 2 — Matrix client issues

### 2.1 Element can't connect to the homeserver

Check the discovery chain:

```bash
# 1. .well-known (client discovery)
curl -s https://matrix.example.com/.well-known/matrix/client | python3 -m json.tool

# 2. Synapse itself
curl -s https://matrix.example.com/_matrix/client/versions | head -c 60

# 3. Caddy is serving TLS correctly
curl -sI https://matrix.example.com | head -5
```

If `.well-known` is missing or malformed, Element can't find your homeserver. Check the Caddyfile has:

```caddy
handle /.well-known/matrix/client {
    header Content-Type application/json
    respond `{"m.homeserver":{"base_url":"https://matrix.example.com/"}}` 200
}
```

### 2.2 "Invalid username or password" but they're correct

Element sends credentials to `https://matrix.example.com/_matrix/client/v3/login`. If this fails:

```bash
# Test manually
curl -s -X POST https://matrix.example.com/_matrix/client/v3/login \
  -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"yourusername"},"password":"yourpassword"}'
```

| Response | Cause |
|---|---|
| `403 M_FORBIDDEN` | Wrong username/password, or account deactivated |
| `404 M_NOT_FOUND` | Wrong URL — client can't find homeserver |
| `429 M_LIMIT_EXCEEDED` | Rate-limited — wait 15 min |
| `502` from Caddy | Synapse not running |

### 2.3 Messages aren't syncing

Element uses `GET /_matrix/client/v3/sync?timeout=30000` (long-polling). If sync hangs:

```bash
# Watch Synapse logs during sync
docker logs -f synapse 2>&1 | grep 'sync'
```

You should see lines like:

```text
GET-... Processed request: 30.005sec/0.000sec ... 200 "GET /_matrix/client/v3/sync?..."
```

- **No `sync` lines at all** → client isn't reaching Synapse. Check `.well-known` and Caddy routing.
- **`sync` lines but responses are 4xx/5xx** → Synapse errors. Check the error in the log.
- **`sync` lines but `30.005sec` and `200`** → working correctly (long-poll timeout).

### 2.4 Encryption keys not syncing

Matrix E2EE requires device key backups. If Element shows "unable to decrypt":

```bash
docker logs synapse 2>&1 | grep -iE 'key|e2ee|encrypt'
```

Common issues:
- **`No cross-signing key`** → user needs to verify their device
- **`Unable to load device keys`** → key backup may be corrupted

This is usually a client-side issue (Element settings → Security & Privacy → verify device). If it's server-side, check Synapse's `e2ee` config.

---

## Part 3 — Voice/video calls (MatrixRTC)

This is where most issues happen. Calls have several moving parts: discovery, token issuance, LiveKit connection, media negotiation.

### 3.1 "Call rings but no media" (black screen, no audio)

**This was the most common failure during development.** The call connects (both sides see the call ring and answer), but no audio/video flows.

**Check the logs during a failed call:**

```bash
docker logs livekit 2>&1 | grep -iE 'participant|track|codec|error' | tail -40
docker logs lk-jwt 2>&1 | grep -iE 'get_token|create|error' | tail -20
```

**Look for these patterns:**

| Log pattern | Meaning | Fix |
|---|---|---|
| `dependencyDescriptorExtID mismatch` | Codec negotiation issue | Remove VP9/AV1 from `enabled_codecs` (see 3.2) |
| `participant connected` for one but not both | One side can't reach LiveKit | Check TURN, firewall, WebSocket path |
| `no suitable ICE candidate pair` | ICE/network failure | Check TURN, NAT, LAN IP advertising |
| `track_published` but no `track_subscribed` | Subscription issue | Usually codec or TURN issue |

**The most common cause: Caddy serving `/rtc/transports` statically.**

Check:

```bash
curl -i -s https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports | head -5
```

| Response | Meaning |
|---|---|
| `HTTP/2 401` + `server: Synapse/...` | ✓ Correct (endpoint served by Synapse, requires auth) |
| `HTTP/2 200` + `server: Caddy` + JSON | ❌ Broken (static Caddy response) |
| `HTTP/2 404` | ❌ Broken (endpoint not registered in Synapse) |

**Fix for static Caddy response:** remove the `handle /_matrix/client/unstable/org.matrix.msc4143/rtc/transports` block from `/etc/caddy/Caddyfile`. Synapse serves it natively when `matrix_rtc.transports` is in `homeserver.yaml` and `msc4143_enabled: true` is in `experimental_features`.

### 3.2 `dependencyDescriptorExtID mismatch` in LiveKit logs

```text
INFO livekit.sub sfu/downtrack.go:869 dependencyDescriptorExtID mismatch
  {"current": 6, "negotiated": 12}
```

This means the JS SDK (Element Desktop) and Rust SDK (Element X) are negotiating different numeric IDs for the AV1/VP9 dependency descriptor RTP header extension. LiveKit can't bridge them.

**Root cause:** VP9 or AV1 is enabled in `enabled_codecs`, and the two SDKs assign different extension IDs.

**Fix:** remove VP9 and AV1 from `enabled_codecs`:

```yaml
# ~/matrix/rtc/livekit/livekit.yaml
room:
  enabled_codecs:
    - mime: video/VP8
    - mime: video/H264
    - mime: audio/opus
```

Then recreate LiveKit:

```bash
cd ~/matrix/rtc
docker compose up -d --force-recreate livekit
```

VP8 uses the dependency descriptor only for simulcast layers (which both SDKs handle identically). H264 doesn't use it at all. VP9/AV1 use it for every frame, triggering the mismatch.

**Verify:** after the fix, `dependencyDescriptorExtID mismatch` should not appear in the logs during calls.

### 3.3 "Unable to create room on SFU" / `/jwt/sfu/get` errors

This appears in Element when lk-jwt can't create a LiveKit room.

**Check lk-jwt logs:**

```bash
docker logs lk-jwt 2>&1 | grep -iE 'error|create'
```

| Error | Cause | Fix |
|---|---|---|
| `401 Unauthorized` on `CreateLiveKitRoom` | API secret mismatch | Compare `LIVEKIT_SECRET` in `lk-jwt/.env` to `keys:` in `livekit.yaml` |
| `connection refused` | lk-jwt can't reach LiveKit | Check LiveKit is running + port 7880 |
| `Application service configuration` missing | AS mode not active | Check `LIVEKIT_AS_TOKEN`, `LIVEKIT_HS_TOKEN`, `LIVEKIT_HS_SERVER_NAME` in `.env` |
| `The app service token(s) ... must either all be set or all be left empty` | Partial AS config | Set all 3 AS vars or none |

**The API secret mismatch** is the most common. The `LIVEKIT_SECRET` in `~/matrix/rtc/lk-jwt/.env` **must match exactly** the value in `~/matrix/rtc/livekit/livekit.yaml` under `keys:`. Even one character off breaks token signing:

```
livekit.yaml:  keys:
                 60c2f2fe76245fb6: fa1f52dd...
lk-jwt/.env:   LIVEKIT_KEY=60c2f2fe76245fb6
               LIVEKIT_SECRET=fa1f52dd...    ← must match exactly
```

If you recently edited either file, check for:
- Trailing whitespace
- Missing characters at the end
- Wrong key/secret (swapped)

**Verify:**

```bash
# Compare
grep -A1 '^keys:' ~/matrix/rtc/livekit/livekit.yaml
grep 'LIVEKIT_SECRET' ~/matrix/rtc/lk-jwt/.env
```

The secret values should be identical.

### 3.4 iPhone ↔ iPhone works, but iPhone ↔ Desktop fails

This is the cross-SDK case: Rust Matrix SDK (iPhone) ↔ JS Matrix SDK (Desktop).

**If the call rings but no media:** check `dependencyDescriptorExtID` (3.2) and `/rtc/transports` (3.1).

**If the call doesn't ring at all:** the client is failing at discovery or token issuance. Check:

```bash
# Watch Synapse for the /rtc/transports request
docker logs -f synapse 2>&1 | grep -iE 'rtc|transports|4143'

# Watch lk-jwt for the token request
docker logs -f lk-jwt 2>&1 | grep -iE 'get_token|create'
```

**If both log activity but no call UI appears:** client-side caching. Force-quit both clients, reopen.

### 3.5 Calls drop after a few seconds

The call connects, then drops. This is usually a network/ICE issue.

```bash
docker logs livekit 2>&1 | grep -iE 'ice|dtls|disconnect|timeout'
```

Common causes:
- **ICE timeout:** TURN relay failing. Check `ss -ulnp | grep 3479` and `grep 50300` on the Pi.
- **DTLS failure:** usually a TLS/cert issue in the WebRTC handshake, but rare.
- **LiveKit restart:** check `docker ps --filter name=livekit` — was it restarted?

### 3.6 "Server ID error" on Element X

Element X shows "server id error" when it can't determine the SFU identity.

```bash
# Check .well-known
curl -s https://matrix.example.com/.well-known/matrix/client | python3 -m json.tool

# Check /rtc/transports (must be 401, not 200)
curl -i -s https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports | head -5
```

If `/rtc/transports` returns `HTTP/2 200` from Caddy, see 3.1.

If `/rtc/transports` returns `HTTP/2 401` from Synapse and `.well-known` is correct, force-quit Element X and reopen. If it persists, check the `livekit_service_url` in `.well-known` is exactly `https://matrix.example.com/livekit/jwt` (no trailing slash).

### 3.7 LiveKit TURN not working

LiveKit's embedded TURN is required for clients behind restrictive NAT.

```bash
# Check LiveKit's TURN is bound
sudo ss -ulnp | grep 3479
# → should show livekit-server on 0.0.0.0:3479 or similar

# Check LiveKit startup logs
docker logs livekit 2>&1 | grep -i 'turn'
# → "Starting TURN server {...}"
```

If TURN isn't bound, check `livekit.yaml`:

```yaml
turn:
  enabled: true
  domain: matrix.example.com
  udp_port: 3479
  relay_range_start: 50300
  relay_range_end: 50310
```

**Do NOT add a `secret:` field** — LiveKit's embedded TURN uses the API key/secret from the `keys:` block. A `secret:` field causes:

```text
could not parse config: yaml: unmarshal errors:
  field secret not found in type config.TURNConfig
```

If you see that error, remove the `secret:` line from `turn:`.

### 3.8 `delegate_delayed_leave` errors in lk-jwt logs

```text
ERROR lk_jwt_service::handler: Handler: delegate_delayed_leave:
  error reading body err=EOF while parsing a value at line 1 column 0
```

This is a **client-side bug** in current Element X / Flatpak versions. The client hits the endpoint with an empty body, and lk-jwt can't parse it.

**It doesn't affect calls.** Calls work fine; the MSC4140 "clean leave on disconnect" mechanism just doesn't work.

**Workaround:** enable the pull-based sanity check in `~/matrix/rtc/lk-jwt/.env`:

```bash
LIVEKIT_SANITY_CHECK_INTERVAL_SECONDS=30
```

Then restart lk-jwt:

```bash
cd ~/matrix/rtc
docker compose up -d --force-recreate lk-jwt
```

This polls LiveKit every 30 seconds to detect disconnected participants, cleaning them up even when `delegate_delayed_leave` fails. The error log will still appear, but stale participants get cleaned up.

### 3.9 AS proxy returns 502

Synapse's AS proxy path (`/_matrix/client/unstable/io.element.msc4195/rtc/livekit/*`) forwards to lk-jwt. If this fails:

```bash
# From inside Synapse's container
docker exec synapse python3 -c "import socket; s=socket.create_connection(('172.17.0.1', 8081), timeout=3); print('OK'); s.close()"
```

| Result | Cause | Fix |
|---|---|---|
| `OK` | Network is fine | Check Synapse logs for the actual error |
| `ConnectionRefusedError` | lk-jwt not bound on `172.17.0.1` | Check `~/matrix/rtc/docker-compose.yml` has both port bindings |
| `TimeoutError` | Firewall blocking the bridge | Check `sudo iptables -L` and Docker's iptables rules |

**The fix for ConnectionRefused:** `~/matrix/rtc/docker-compose.yml` must have **both** port bindings on lk-jwt:

```yaml
ports:
  - "127.0.0.1:8081:8080"      # for Caddy
  - "172.17.0.1:8081:8080"     # for Synapse
```

Without the second, Synapse can't reach lk-jwt via the docker bridge.

Verify with:

```bash
sudo ss -tlnp | grep 8081
# → should show TWO listeners: 127.0.0.1:8081 and 172.17.0.1:8081
```

---

## Part 4 — Federation issues

### 4.1 Federation tester shows errors

Use the Matrix federation tester:

```
https://federationtester.matrix.org/#matrix.example.com
```

Common failures:

| Failure | Cause | Fix |
|---|---|---|
| `No valid A records` | DNS not pointing at server | Check `dig +short matrix.example.com` |
| `Connection refused` on 8448 | Federation port not open | This stack uses 443 for federation (via Caddy), so 8448 isn't needed |
| `TLS error` | Caddy cert invalid | `curl -sI https://matrix.example.com/_matrix/key/v2/server` |
| `Invalid response` | Synapse `server_name` mismatch | Check `server_name: "matrix.example.com"` in `homeserver.yaml` |

### 4.2 Other servers reject my events

This is the **signing key** problem. If your signing key changed (or is missing), federated servers see events signed by an unrecognized key and reject them.

```bash
head -1 ~/matrix/data/matrix.example.com.signing.key
```

If the key is missing or different from before, federation is broken. See [BACKUP-RESTORE.md](BACKUP-RESTORE.md) Scenario B.

**Prevention:** back up the signing key in multiple encrypted locations.

### 4.3 Can't join federated rooms

Federation requires bidirectional trust. If you can't join a room on another homeserver:

1. Check your server's federation works: `https://federationtester.matrix.org/#matrix.example.com`
2. Check the other server is reachable: `curl -sI https://otherserver.example/_matrix/key/v2/server`
3. Check Synapse logs for federation errors:

```bash
docker logs synapse 2>&1 | grep -i federation
```

---

## Part 5 — Resource and performance

### 5.1 Pi is slow during calls

A 6-person call uses ~60–80% CPU. If other services are competing:

```bash
# See what's using CPU
htop

# Docker container stats
docker stats --no-stream

# Disk I/O
sudo iostat -x 5 2
```

| Issue | Fix |
|---|---|
| LiveKit CPU spikes | Expected — SFU forwards all media. Reduce participants per call. |
| Synapse CPU spikes | Usually DB queries. Check `docker logs synapse \| grep slow`. |
| Nextcloud competing | Reduce PHP-FPM workers, or move to separate host. |
| Disk I/O slow | Use SSD (NVMe HAT for Pi 5). microSD cards are too slow. |

### 5.2 Out of memory

```bash
free -h
dmesg | grep -i 'killed process'
```

If the kernel is OOM-killing containers:

| Container | Typical RAM | Can reduce |
|---|---|---|
| Synapse | 500MB–1.5GB | Yes (DB cache limits) |
| LiveKit | 200–500MB | No |
| lk-jwt | 50–100MB | No |
| Caddy | 50MB | No |
| Nextcloud | 300–600MB | Yes (PHP workers) |

**Fix:** reduce Synapse's cache size in `homeserver.yaml`:

```yaml
caches:
  global_factor: 0.5    # default is 1.0
```

Or add more RAM. The Pi 5 supports up to 8GB (you have that).

### 5.3 Disk full

```bash
df -h
docker system df
du -sh ~/matrix/data/media_store
```

Common causes:
- **media_store growing** — Synapse stores all uploaded images/videos. Set a limit in `homeserver.yaml`:

```yaml
media_store_path: /data/media_store
max_upload_size: 50M
```

- **Docker images** — `docker image prune -f`
- **Logs** — `sudo journalctl --vacuum-size=100M`
- **Backups** — old backups in `~/backups/matrix/`. Prune with `find ... -mtime +30 -delete`.

---

## Part 6 — Backup and restore issues

### 6.1 Backup fails with "permission denied"

The backup script runs `sudo cp` for files owned by UID 991. If sudo is cached, it works without a prompt. If not:

```bash
# Force a sudo prompt before running the script
sudo -v
~/backup-matrix.sh
```

### 6.2 "Not in gzip format" when verifying

The script picked the wrong file. Check:

```bash
ls -la ~/backups/matrix/
```

If there's a `.sha256` file matching the `*.tar.gz*` glob, the verification script might pick it instead of the archive. The fixed script (see `scripts/check-backup.sh`) handles this correctly by preferring `.tar.gz` over `.tar.gz.gpg`, and never matching `.sha256`.

### 6.3 Database integrity check fails

```bash
sqlite3 ~/matrix/data/homeserver.db "PRAGMA integrity_check;"
# → not "ok"
```

This means the DB is corrupt. **Do not use this backup** — restore from an older, valid one. See [BACKUP-RESTORE.md](BACKUP-RESTORE.md) Scenario A.

---

## Part 7 — Quick diagnostic checklist

When something breaks, run through this in order:

```bash
# 1. Are all containers running?
docker ps --filter name=synapse --filter name=livekit --filter name=lk-jwt \
  --format 'table {{.Names}}\t{{.Status}}'

# 2. Is Caddy serving?
sudo systemctl status caddy
curl -sI https://matrix.example.com | head -1

# 3. Is Synapse responding?
curl -s https://matrix.example.com/_matrix/client/versions | head -c 60

# 4. Is lk-jwt responding?
curl -sI https://matrix.example.com/livekit/jwt/healthz | head -1

# 5. Is LiveKit responding?
curl -sI https://matrix.example.com/livekit/sfu/ | head -1

# 6. Is transport discovery correct?
curl -i -s https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports | head -5

# 7. Are logs clean?
docker logs --tail 20 synapse 2>&1 | grep -iE 'error|warn'
docker logs --tail 20 livekit 2>&1 | grep -iE 'error|warn'
docker logs --tail 20 lk-jwt 2>&1 | grep -iE 'error|warn'

# 8. Is the signing key present?
ls -la ~/matrix/data/*.signing.key
```

The output of each step tells you where the failure is.

---

## Part 8 — Where to get more help

### Matrix community

- **`#synapse:matrix.org`** — Synapse support
- **`#element-call:matrix.org`** — Element Call / MatrixRTC support
- **`#livekit:matrix.org`** — LiveKit (unofficial)

### GitHub issues

- **Synapse:** `https://github.com/element-hq/synapse/issues`
- **LiveKit:** `https://github.com/livekit/livekit/issues`
- **lk-jwt:** `https://github.com/element-hq/lk-jwt-service/issues`
- **Element Call:** `https://github.com/element-hq/element-call/issues`
- **Element X:** `https://github.com/element-hq/element-x-ios/issues` (iOS), `.../element-x-android` (Android)

### This repo

- Open an issue: `https://github.com/jonathonp3/matrix-homeserver-stack/issues`
- Include logs, `docker ps` output, and the relevant config file (redacted)

---

## See also

- [`INSTALL.md`](INSTALL.md) — installation walkthrough
- [`CONFIGURATION.md`](CONFIGURATION.md) — every config file explained
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — components and data flow
- [`PORTS-AND-FIREWALL.md`](PORTS-AND-FIREWALL.md) — port map and UFW
- [`DOCKER-COMMANDS.md`](DOCKER-COMMANDS.md) — common Docker commands
- [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md) — backup and restore
- [`FEDERATION.md`](FEDERATION.md) — federation setup
