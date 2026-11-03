# Ports, Router Forwarding, and UFW

Complete reference for the network ports used by `matrix-homeserver-stack`, how to forward them on your router, and how to configure the host firewall (UFW).

---

## Part 1 — Why these ports

The stack runs four services that need network access:

| Service | Purpose | What clients connect to |
|---|---|---|
| **Caddy** | Reverse proxy + TLS | `https://matrix.example.com` (443) |
| **LiveKit** | Media SFU + embedded TURN | UDP media ports directly (not via Caddy) |
| **lk-jwt** | Token issuance | Via Caddy at `/livekit/jwt/*` |
| **Synapse** | Matrix homeserver | Via Caddy at `/_matrix/*` |

**Only Caddy (80/443) and LiveKit's UDP ports need to be forwarded from the internet.** Everything else is reached through Caddy or is internal-only.

---

## Part 2 — Complete port map

### 2.1 Externally forwarded (from router)

| Port | Protocol | Service | Purpose |
|---|---|---|---|
| `80` | TCP | Caddy | ACME HTTP challenge (Let's Encrypt) + HTTPS redirect |
| `443` | TCP | Caddy | HTTPS for everything: Synapse, lk-jwt, LiveKit WebSocket |
| `3479` | UDP | LiveKit | Embedded TURN control port |
| `7881` | TCP | LiveKit | TCP fallback for media when UDP fails |
| `50000–50020` | UDP | LiveKit | Direct WebRTC media (21 ports) |
| `50300–50310` | UDP | LiveKit | TURN relay media (11 ports) |

**Total: 36 router rules** (or ~5 if your router supports port ranges).

### 2.2 Internal only (do NOT forward)

| Port | Protocol | Service | Why not forwarded |
|---|---|---|---|
| `8008` | TCP | Synapse | Reached via Caddy (443) |
| `7880` | TCP | LiveKit HTTP API | Reached via Caddy (443) at `/livekit/sfu/*` |
| `8080` | TCP | lk-jwt (container port) | Reached via Caddy (443) at `/livekit/jwt/*` |
| `8081` | TCP | lk-jwt (host port) | Reached via Caddy (443) and Synapse (AS proxy) |

If you're coming from an older setup, you might also see references to `3478`, `5349`, `49152–49171` — those are **legacy coturn** and are **not used** in this stack. See Part 6.

### 2.3 Docker-internal (not exposed on host)

| Address | Purpose |
|---|---|
| `172.17.0.1:8081` | lk-jwt bound to docker bridge for Synapse's AS proxy |
| `127.0.0.1:8081` | lk-jwt bound to loopback for Caddy |
| `127.0.0.1:8008` | Synapse bound to loopback for Caddy |
| `127.0.0.1:7880` | LiveKit HTTP bound to loopback for Caddy (via `network_mode: host`) |

These are reached by Caddy and Synapse from the host, not from the internet.

---

## Part 3 — Router forwarding

### 3.1 What to forward

Forward **all** of Part 2's "Externally forwarded" ports to the **internal IP of the host** running the stack (e.g., `192.168.50.162`).

| Service Name | External Port | Internal Port | Internal IP | Protocol |
|---|---|---|---|---|
| HTTP | 80 | 80 | 192.168.50.162 | TCP |
| HTTPS | 443 | 443 | 192.168.50.162 | TCP |
| LiveKit-TCP | 7881 | 7881 | 192.168.50.162 | TCP |
| LiveKit-TURN | 3479 | 3479 | 192.168.50.162 | UDP |
| LiveKit-UDP-01 | 50000 | 50000 | 192.168.50.162 | UDP |
| ... | ... | ... | ... | UDP |
| LiveKit-UDP-21 | 50020 | 50020 | 192.168.50.162 | UDP |
| Turn-Relay-01 | 50300 | 50300 | 192.168.50.162 | UDP |
| ... | ... | ... | ... | UDP |
| Turn-Relay-11 | 50310 | 50310 | 192.168.50.162 | UDP |

### 3.2 If your router supports port ranges

Many enterprise-class routers (UniFi, pfSense, OPNsense, some Asus/Netgear) accept ranges in a single rule:

```text
50000-50020  UDP  →  192.168.50.162
50300-50310  UDP  →  192.168.50.162
```

That reduces 36 rules to **5**:

- 80 (TCP)
- 443 (TCP)
- 3479 (UDP)
- 50000-50020 (UDP)
- 50300-50310 (UDP)
- 7881 (TCP)

If your router doesn't support ranges, add the rules one at a time (36 rules total).

### 3.3 If your router has a 64-rule limit

36 rules is fine. If you also run Nextcloud or other services, you have ~28 rules for those.

If you need more headroom:

- Reduce LiveKit UDP media range from 21 to 15 ports (`50000-50014` in `livekit.yaml`) — saves 6 rules
- Reduce LiveKit TURN relay range from 11 to 6 ports (`50300-50305`) — saves 5 rules

Both still support 6-person calls with reconnections.

### 3.4 If you use DDNS

If your public IP changes (residential connection), you need DDNS to keep DNS pointing at the right IP. The stack includes a DDNS updater for NameSilo (`scripts/update_domain.sh`), but other options:

- **Your router's built-in DDNS** (most support No-IP, DuckDNS, Cloudflare)
- **`ddclient`** or **`inadyn`** on the Pi
- **A cron script** that hits your DNS provider's API

The DNS record to update: `matrix.example.com` A record → current public IP.

See [`DNS-ROUTER-CONFIGURATION.md`](DNS-ROUTER-CONFIGURATION.md) for NameSilo setup.

---

## Part 4 — UFW (host firewall)

### 4.1 Why UFW

Even with router port forwarding, you should have a host firewall (UFW) so that:

- Only forwarded ports are accessible from the LAN
- Internal services (Synapse on 8008, LiveKit HTTP on 7880) aren't reachable from other LAN devices unless you want them to be
- If the router config ever changes, the Pi still only exposes the intended ports

### 4.2 Install UFW

```bash
sudo apt install -y ufw
```

### 4.3 Configure UFW

Add rules for the ports that the router forwards. These must be open on the host for the router's forwards to work.

```bash
# HTTP / HTTPS (Caddy)
sudo ufw allow 80/tcp comment 'Caddy HTTP'
sudo ufw allow 443/tcp comment 'Caddy HTTPS'

# LiveKit TCP fallback
sudo ufw allow 7881/tcp comment 'LiveKit TCP fallback'

# LiveKit embedded TURN
sudo ufw allow 3479/udp comment 'LiveKit TURN control'

# LiveKit UDP media
sudo ufw allow 50000:50020/udp comment 'LiveKit media UDP'

# LiveKit TURN relay
sudo ufw allow 50300:50310/udp comment 'LiveKit TURN relay UDP'
```

### 4.4 Enable UFW

```bash
# Default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (IMPORTANT — do this before enabling!)
sudo ufw allow 22/tcp comment 'SSH'

# Enable
sudo ufw enable
```

**⚠️ Always allow SSH before enabling UFW.** If you lock yourself out, you'll need physical console access to fix it.

### 4.5 Verify

```bash
sudo ufw status verbose
```

Expected:

```text
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere                   # SSH
80/tcp                     ALLOW IN    Anywhere                   # Caddy HTTP
443/tcp                    ALLOW IN    Anywhere                   # Caddy HTTPS
7881/tcp                   ALLOW IN    Anywhere                   # LiveKit TCP fallback
3479/udp                   ALLOW IN    Anywhere                   # LiveKit TURN control
50000:50020/udp            ALLOW IN    Anywhere                   # LiveKit media UDP
50300:50310/udp            ALLOW IN    Anywhere                   # LiveKit TURN relay UDP
22/tcp (v6)                ALLOW IN    Anywhere (v6)              # SSH
80/tcp (v6)                ALLOW IN    Anywhere (v6)              # Caddy HTTP
443/tcp (v6)               ALLOW IN    Anywhere (v6)              # Caddy HTTPS
...
```

### 4.6 What's NOT in UFW (and why)

| Port | Why it's not open |
|---|---|
| `8008` (Synapse) | Only reachable through Caddy on `127.0.0.1` |
| `7880` (LiveKit HTTP) | Only reachable through Caddy on `127.0.0.1` (`network_mode: host`) |
| `8080` (lk-jwt container) | Container-internal; mapped to `127.0.0.1:8081` |
| `8081` (lk-jwt host) | Bound to `127.0.0.1` and `172.17.0.1`; not externally reachable |
| `3478`, `5349`, `49152–49171` | Legacy coturn ports; coturn has been removed |

The only ports the outside world can reach are the ones you forwarded on the router, and the only ports open in UFW are those same ones. Everything else is internal.

### 4.7 If you need to reach Synapse from another LAN device

Some setups want other LAN devices (e.g., an admin laptop) to reach Synapse directly on 8008 for debugging. By default, Synapse is bound to `127.0.0.1:8008` (loopback only), so other LAN devices can't reach it even with UFW open.

If you want to expose Synapse on the LAN:

1. In `~/matrix/docker-compose.yml`, change `"127.0.0.1:8008:8008"` to `"192.168.50.162:8008:8008"`:

```yaml
ports:
  - "192.168.50.162:8008:8008"    # was: 127.0.0.1:8008:8008
```

2. Open the port in UFW:

```bash
sudo ufw allow from 192.168.50.0/24 to any port 8008 proto tcp comment 'Synapse (LAN only)'
```

3. Restart Synapse.

**But** — this is not recommended. It exposes Synapse without Caddy's TLS, which is only safe on a trusted LAN. For debugging, use `docker logs synapse` instead.

---

## Part 5 — Verifying the setup from outside

After configuring router + UFW, test from a device outside your LAN (phone on cellular, external VPS).

### 5.1 HTTPS endpoints

```bash
# Synapse client API
curl -s https://matrix.example.com/_matrix/client/versions | head -c 60
# → {"versions":["r0.0.1",...

# .well-known
curl -s https://matrix.example.com/.well-known/matrix/client | python3 -m json.tool

# lk-jwt health
curl -sI https://matrix.example.com/livekit/jwt/healthz | head -1
# → HTTP/2 200

# LiveKit
curl -sI https://matrix.example.com/livekit/sfu/ | head -1
# → HTTP/2 200
```

### 5.2 LiveKit UDP ports

```bash
# From a machine outside your LAN with nc installed
nc -u -zv matrix.example.com 3479
# → connected (or "succeeded")

nc -u -zv matrix.example.com 50000
# → connected

nc -u -zv matrix.example.com 50300
# → connected
```

If any of these fail (timeout), the router forward isn't working or UFW is blocking.

### 5.3 LiveKit TCP fallback

```bash
nc -v matrix.example.com 7881
# → connected (or "succeeded")
```

### 5.4 What to check if tests fail

| Symptom | Likely cause | Fix |
|---|---|---|
| All HTTPS fails | Router forward for 80/443 missing | Add forward |
| HTTPS works, UDP fails | UDP forwards missing (3479, 50000–50020, 50300–50310) | Add forwards |
| HTTPS works, TCP 7881 fails | 7881 forward missing | Add forward |
| Some UDP works, some don't | Router rejected some rules, or firewall partially configured | Check `sudo ufw status verbose` |
| Everything fails | Caddy not running, or router config not applied | Run `sudo systemctl status caddy` |

---

## Part 6 — If you have legacy coturn

If you previously had coturn (the old setup), you can remove these forwards — they're not used by this stack:

| Port | Protocol | What it was for |
|---|---|---|
| 3478 | TCP+UDP | coturn TURN control |
| 5349 | TCP+UDP | coturn TURN/TLS |
| 49152–49171 | UDP | coturn relay range |

**Total freed: ~22 router rules.**

Remove these rules from your router. Also remove any UFW rules for them:

```bash
sudo ufw delete allow 3478/tcp
sudo ufw delete allow 3478/udp
sudo ufw delete allow 5349/tcp
sudo ufw delete allow 5349/udp
sudo ufw delete allow 49152:49171/udp
```

And remove `turn_uris` / `turn_shared_secret` / `turn_user_lifetime` / `turn_allow_guests` from `~/matrix/data/homeserver.yaml`. Restart Synapse.

### Why coturn is gone

Legacy 1:1 calling (`m.call.*`) only works between Element Desktop clients. It can't reach Element X (iPhone/Android), because Element X dropped legacy support.

In a mixed iPhone + desktop environment, legacy calls are useless. Only MatrixRTC (Element Call) works, and that uses LiveKit's embedded TURN (ports 3479, 50300–50310).

Removing coturn:

- Simplifies the stack (one TURN server instead of two)
- Frees 22 router rules
- Removes a service that could fail and take calls down

---

## Part 7 — Complete port reference table

| Port | Protocol | Service | Where it's used | Forwarded? | UFW? |
|---|---|---|---|---|---|
| 22 | TCP | SSH | Host | No (unless remote SSH) | Yes |
| 80 | TCP | Caddy | Host | Yes | Yes |
| 443 | TCP | Caddy | Host | Yes | Yes |
| 3479 | UDP | LiveKit TURN | Host (`network_mode: host`) | Yes | Yes |
| 7880 | TCP | LiveKit HTTP | Host (loopback) | No | No |
| 7881 | TCP | LiveKit TCP | Host (`network_mode: host`) | Yes | Yes |
| 8008 | TCP | Synapse | Host (loopback) | No | No |
| 8080 | TCP | lk-jwt (container) | Container | No | No |
| 8081 | TCP | lk-jwt (host) | Host (loopback + Docker bridge) | No | No |
| 50000–50020 | UDP | LiveKit media | Host (`network_mode: host`) | Yes | Yes |
| 50300–50310 | UDP | LiveKit TURN relay | Host (`network_mode: host`) | Yes | Yes |

**Note:** LiveKit uses `network_mode: host`, which means its ports bind directly to the host interfaces (not Docker's port mapping). That's why UFW rules work for LiveKit's ports.

Synapse and lk-jwt use Docker port mappings (`127.0.0.1:8008` and `127.0.0.1:8081`), which means Docker's iptables rules handle the forwarding. UFW rules aren't strictly needed for loopback-bound ports (they're only reachable from the host itself).

---

## Part 8 — Troubleshooting

### 8.1 UFW blocks a port that's forwarded

Docker's iptables rules can bypass UFW. If a Docker-managed port is reachable from outside even though UFW says "deny", that's because Docker inserts its own `iptables` rules before UFW's.

**Fix:** use `ufw-docker` or configure Docker's iptables to respect UFW. For this stack, it doesn't matter — the only Docker ports exposed externally are the ones you intend (via router forwards). But if you add other Docker services in the future, keep this in mind.

### 8.2 Router shows "connected" but port test fails

If `nc -u` says "connected" but no data flows, the router forward may be pointing at the wrong internal IP, or the host firewall is dropping packets after the router forwards them.

**Debug:**

```bash
# On the Pi, watch for incoming packets on the port
sudo tcpdump -i any -n udp port 3479

# From outside, send traffic
nc -u -zv matrix.example.com 3479
```

If `tcpdump` shows packets arriving but the service doesn't respond, UFW or the service itself is the issue. If `tcpdump` shows nothing, the router forward is broken.

### 8.3 Caddy keeps requesting certs

If Caddy's `/var/lib/caddy` gets wiped (e.g., on reinstall), it re-requests Let's Encrypt certs. Let's Encrypt has a rate limit of 5 certs per week per domain. If you reinstall 5+ times in a week, you'll be blocked.

**Fix:** back up `/var/lib/caddy` as part of the matrix backup (the `backup-matrix.sh` script does this). Restoring it avoids re-requesting.

### 8.4 TURN port range too small

If 6-person calls fail with "no relay port available" in LiveKit logs, expand `relay_range_end` in `livekit.yaml` and forward the new ports.

Default: `50300–50310` (11 ports). For 6 people, that's enough. For 10+ people, expand to `50300–50319` (20 ports).

---

## Summary

| Task | Command / config |
|---|---|
| Forward ports on router | 80, 443, 3479, 7881, 50000–50020, 50300–50310 |
| Configure UFW | Add `ufw allow` rules for each of the above |
| Remove legacy coturn | Remove forwards for 3478, 5349, 49152–49171 |
| Verify externally | Test HTTPS endpoints with `curl`; check UDP ports with `nc -u` |
| Debug firewall | Run `tcpdump` on the Pi and check `sudo ufw status verbose` |
| If ports fail | Check router forwarding, UFW, and Docker's iptables rules |

**The key insight:** only Caddy (80/443) and LiveKit's UDP ports (3479, 50000-50020, 50300-50310) and TCP (7881) need to be reachable from the internet. Everything else is internal.

---

## See also

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — component diagram and data flow
- [`INSTALL.md`](INSTALL.md) — installation walkthrough
- [`DNS-ROUTER-CONFIGURATION.md`](DNS-ROUTER-CONFIGURATION.md) — NameSilo DNS, router setup, UFW, install script
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures
- [`../examples/router-forwards.md`](../examples/router-forwards.md) — quick checklist
