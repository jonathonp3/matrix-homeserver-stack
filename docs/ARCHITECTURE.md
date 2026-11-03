# Architecture

How the components of `matrix-homeserver-stack` fit together.

---

## Overview

The stack runs four main services plus a reverse proxy:

```
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
      │             │             │
      │  AS proxy   │             │
      └────────────►│             │
                    │             │
                    └────────────►│
                                  │
                                  ▼
                          Media + TURN
                          (UDP 50000-50020, 3479, 50300-50310)
```

Each component has a specific job:

| Component | Job | Port |
|---|---|---|
| **Caddy** | Reverse proxy, TLS termination, routing | 80, 443 |
| **Synapse** | Matrix homeserver (client API, federation) | 8008 |
| **lk-jwt** | Issues LiveKit tokens, verifies room membership | 8081 |
| **LiveKit** | SFU — routes media between participants | 7880, 7881, 3479, 50000-50020, 50300-50310 |

---

## Component roles

### Caddy

The **entry point** for everything. Handles:

- **TLS** — automatic Let's Encrypt certificates for `matrix.example.com` and `example.com`
- **HTTP → HTTPS redirects** — port 80 to 443
- **`.well-known` endpoints** — static JSON that tells Matrix clients where to find the homeserver
- **Path-based routing** — sends requests to the right backend based on URL prefix
- **HTTP/2 and HTTP/3** — faster client connections

**Why Caddy?** Automatic TLS (no certbot, no cron renewals), simple config syntax, HTTP/3 support. Synapse and LiveKit don't handle TLS themselves in this stack.

### Synapse

The **Matrix homeserver**. Handles:

- **Client-server API** (`/_matrix/client/*`) — what Element talks to
- **Federation API** (`/_matrix/federation/*`) — what other homeservers talk to
- **User management** — registration, login, profiles, devices
- **Room management** — creation, state events, messages
- **Sync** (`/_matrix/client/v3/sync`) — long-polling for new events
- **Application Service proxy** (`/_matrix/client/unstable/io.element.msc4195/rtc/livekit/*`) — forwards livekit token requests to lk-jwt
- **MatrixRTC transport discovery** (`/_matrix/client/unstable/org.matrix.msc4143/rtc/transports`) — tells clients where to find the SFU

**Database:** SQLite (`homeserver.db`). Fine for personal deployments up to a few dozen users. For larger, use PostgreSQL.

### lk-jwt

The **LiveKit JWT service**. Bridges Matrix authentication and LiveKit authorization:

- Receives token requests from Matrix clients (via Synapse's AS proxy, or directly via `/livekit/jwt/*`)
- Verifies the requesting user is joined to the room (via Synapse's AS API — MSC4502)
- Issues a LiveKit token signed with the API secret
- Returns the token + the LiveKit URL the client should connect to
- Handles the `delegate_delayed_leave` webhook (MSC4140) so stale participants get cleaned up

**Why a separate service?** Matrix clients don't have LiveKit API credentials. lk-jwt holds the API secret server-side, verifies room membership, and issues short-lived tokens. Clients never see the secret.

**Mode:** Application Service (AS) — registers with Synapse, has its own AS/HS tokens, uses `/_matrix/client/unstable/io.element.msc4195/rtc/livekit/*` for proxied requests.

### LiveKit

The **Selective Forwarding Unit (SFU)**. Handles:

- **WebSocket signaling** (`ws://.../livekit/sfu/*`) — clients connect here to join rooms
- **Media routing** (UDP 50000-50020) — forwards audio/video streams between participants
- **TURN relay** (UDP 3479 + 50300-50310) — relay for clients behind restrictive NAT
- **Room lifecycle** — creates, tracks, and destroys rooms (triggered by lk-jwt API calls)

**Why an SFU instead of peer-to-peer?** For 1:1 calls, peer-to-peer works. For 3+ participants, peer-to-peer becomes N² connections (each client sends to every other client). An SFU is N connections (each client sends to the SFU, the SFU forwards). For group calls, SFU is required.

---

## Data flow: a MatrixRTC call

Here's what happens when Alice (on Element X) calls Bob (on Element Desktop) in a group room:

### 1. Discovery

Alice's client fetches `https://example.com/.well-known/matrix/client`:

```json
{
  "m.homeserver": {"base_url": "https://matrix.example.com/"},
  "org.matrix.msc4143.rtc_foci": [
    {"type": "livekit", "livekit_service_url": "https://matrix.example.com/livekit/jwt"}
  ]
}
```

Tells the client: "Your homeserver is at `matrix.example.com`, and the SFU is reached via `matrix.example.com/livekit/jwt`."

Alice's client also queries Synapse:

```
GET https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports
Authorization: Bearer <alice's access token>
```

Synapse returns:

```json
{
  "rtc_transports": [
    {"type": "livekit", "livekit_service_url": "https://matrix.example.com/livekit/jwt"}
  ]
}
```

**Important:** this endpoint requires authentication. A static Caddy response would break this (see "Design decisions" below).

### 2. Token request

Alice's client asks lk-jwt for a token:

```
POST https://matrix.example.com/_matrix/client/unstable/io.element.msc4195/rtc/livekit/get_token
Authorization: Bearer <alice's access token>
Body: {"room_id": "!abc:matrix.example.com", "slot_id": "m.call#ROOM"}
```

Synapse's AS proxy forwards this to lk-jwt at `http://172.17.0.1:8081/get_token`.

lk-jwt:

1. Verifies Alice's access token with Synapse
2. Checks that Alice is joined to the room (MSC4502)
3. Calls LiveKit's API to create the room (if it doesn't exist)
4. Generates a LiveKit token with Alice's identity and room grants
5. Returns the token + LiveKit URL

### 3. Connect to LiveKit

Alice's client opens a WebSocket to LiveKit:

```
wss://matrix.example.com/livekit/sfu/rtc?access_token=<livekit token>
```

Caddy's `handle_path /livekit/sfu/*` strips the prefix and proxies to `127.0.0.1:7880` (LiveKit). The WebSocket connects.

### 4. Media exchange

Alice publishes her audio/video tracks to LiveKit over UDP (port 50000-50020). If direct UDP fails (restrictive NAT), falls back to LiveKit's embedded TURN (port 3479, relay 50300-50310).

Bob joins the same room:

1. Same discovery (via `.well-known` + `/rtc/transports`)
2. Same token flow (via lk-jwt)
3. Same LiveKit WebSocket
4. LiveKit forwards Alice's tracks to Bob, Bob's to Alice

**Both Alice and Bob use the same LiveKit client SDK** (JS 2.22.3), so media negotiation works — even though Alice is on Element X (Rust Matrix SDK) and Bob is on Element Desktop (JS Matrix SDK). The Matrix SDKs only handle signaling and discovery; media is entirely LiveKit.

### 5. Leave

When Alice hangs up:

1. Her client sends a `m.rtc.member` leave event
2. LiveKit detects the disconnect and notifies lk-jwt via webhook
3. lk-jwt cancels the delegated leave timer
4. If Alice crashes instead of hanging up cleanly, the delegated leave fires after the timeout — Synapse sends a leave event on Alice's behalf

---

## Port map

### Externally reachable (via router forwards)

| Port | Protocol | Service | Purpose |
|---|---|---|---|
| 80 | TCP | Caddy | ACME HTTP challenge + HTTPS redirect |
| 443 | TCP | Caddy | HTTPS for everything |
| 3479 | UDP | LiveKit | Embedded TURN control |
| 7881 | TCP | LiveKit | TCP media fallback |
| 50000-50020 | UDP | LiveKit | Direct WebRTC media |
| 50300-50310 | UDP | LiveKit | TURN relay media |

Full reference: [`PORTS-AND-FIREWALL.md`](PORTS-AND-FIREWALL.md)

### Internal only

| Port | Service | Bound to | Why internal |
|---|---|---|---|
| 8008 | Synapse | `127.0.0.1` | Caddy proxies to it |
| 7880 | LiveKit | `127.0.0.1` | Caddy proxies to it |
| 8080 | lk-jwt (container) | container | Docker port mapping |
| 8081 | lk-jwt (host) | `127.0.0.1` + `172.17.0.1` | Caddy (loopback) + Synapse (bridge) |

**Note on 8081:** lk-jwt binds to both `127.0.0.1:8081` (for Caddy) and `172.17.0.1:8081` (for Synapse's AS proxy). The docker bridge IP (`172.17.0.1`) is reachable from inside Synapse's container. Without the bridge binding, the AS proxy fails with 502.

---

## Why these design decisions

### Why no coturn?

Earlier versions of this stack included coturn for legacy 1:1 calls (`m.call.*`). It's been removed because:

1. **Element is deprecating legacy calling.** The new stack (Element Call) uses MatrixRTC.
2. **Element X (iPhone/Android) dropped legacy support entirely.** Legacy calls can't reach it.
3. **In a mixed environment (iPhone + desktop), legacy calls are useless.** Only MatrixRTC works for all clients.
4. **LiveKit's embedded TURN handles MatrixRTC relay.** No separate TURN server needed.

Removing coturn:
- Frees ~22 router rules
- Removes a service that can fail and take calls down
- Simplifies the stack (one TURN server instead of two)

If you ever need legacy calls, coturn can be added back — but it's not worth the complexity for most deployments.

### Why VP8 + H264 + Opus (no VP9/AV1)?

LiveKit's `enabled_codecs` is restricted to:

```yaml
enabled_codecs:
  - mime: video/VP8
  - mime: video/H264
  - mime: audio/opus
```

**VP9 and AV1 are excluded** because they trigger `dependencyDescriptorExtID mismatch` on LiveKit 1.13.11 when clients use different SDKs (Rust ↔ JS).

The dependency descriptor extension is used differently by VP9/AV1 (for every frame) vs VP8 (only for simulcast layers). When the JS SDK and Rust SDK assign different extension IDs, LiveKit can't bridge the media streams.

**VP8 + H264 + Opus works reliably** across all client combinations:
- VP8: default, simulcast, universal
- H264: fallback, hardware-accelerated on Apple
- Opus: audio

If a future LiveKit version fixes the mismatch, VP9/AV1 can be added back. Until then, VP8 + H264 is the safe set.

### Why no static Caddy handler for `/rtc/transports`?

Earlier versions of this stack had:

```caddy
handle /_matrix/client/unstable/org.matrix.msc4143/rtc/transports {
    respond `{"rtc_transports":[...]}` 200
}
```

This **broke cross-client calls** because:

1. The endpoint requires authentication — clients send an access token
2. A static Caddy response bypasses Synapse entirely
3. Clients got the JSON but never completed the MatrixRTC handshake
4. Result: calls rang but never connected (especially Rust ↔ JS)

**Fix:** remove the static handler. Let Synapse serve the endpoint natively (with auth). This requires:
- `matrix_rtc.transports` in `homeserver.yaml`
- `msc4143_enabled: true` in `experimental_features`

Then `curl -i https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` returns `HTTP/2 401` (correct — needs auth). An authenticated client gets `200` with the JSON.

### Why `advertise_internal_ip: true` on LiveKit?

Without it, LiveKit advertises only the public IP (`115.186.199.122`) in ICE candidates. LAN clients (on the same network as the Pi) must route through the router and back (NAT hairpin), which some routers handle poorly.

With `advertise_internal_ip: true`, LiveKit also advertises the LAN IP (`192.168.50.162`). LAN clients use the direct LAN path, avoiding hairpin entirely. External clients still use the public IP.

### Why `Type=oneshot` for systemd units?

The systemd units use:

```ini
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose up -d
```

This means:
- `docker compose up -d` runs once (at boot), then exits
- systemd marks the service "active" (via `RemainAfterExit=yes`)
- Docker's `restart: always` handles container crashes
- Manual `docker compose restart <service>` works without fighting systemd

The alternative (`Type=simple` with foreground `up`) means systemd supervises the compose process. That's more fragile — manual container restarts can conflict with systemd's supervision.

### Why two port bindings on lk-jwt?

```yaml
ports:
  - "127.0.0.1:8081:8080"      # for Caddy
  - "172.17.0.1:8081:8080"     # for Synapse
```

- Caddy (on the host) reaches lk-jwt via `127.0.0.1:8081`
- Synapse (in a container) reaches lk-jwt via `172.17.0.1:8081` (docker bridge)
- Without the second binding, Synapse's AS proxy path fails (502)

Both bindings point at the same container port (8080).

---

## Deployment architecture

### Single host

Everything runs on one machine:

```
Pi 5 (8GB, SSD)
├── Caddy          (system service)
├── Synapse        (Docker container)
├── LiveKit        (Docker container)
└── lk-jwt         (Docker container)
```

This is the intended deployment. Scales to ~20 concurrent users, ~6 participants per call.

### Multi-node (out of scope)

For higher scale, split:
- **Synapse** → separate host (or worker pool + PostgreSQL)
- **LiveKit** → dedicated SFU host (or cluster of SFUs with Redis for room routing)
- **lk-jwt** → stateless, can scale horizontally (add Redis for shared state)
- **Caddy** → reverse proxy on the edge

This requires changes to compose files, network topology, and database backends. Not covered by this stack.

---

## Security model

### Trust boundaries

| Boundary | What's trusted | What's not |
|---|---|---|
| **Internet → Caddy** | Nothing | All external requests |
| **Caddy → Synapse** | Caddy (on loopback) | Requests from other sources |
| **Caddy → lk-jwt** | Caddy (on loopback) | Requests from other sources |
| **Caddy → LiveKit** | Caddy (on loopback) | Requests from other sources |
| **Synapse → lk-jwt** (AS proxy) | Synapse (via docker bridge) | Requests from other containers |

### What protects what

- **Caddy** terminates TLS. All external traffic is HTTPS.
- **Synapse** verifies Matrix access tokens for client requests.
- **lk-jwt** verifies access tokens + room membership (via AS mode).
- **LiveKit** verifies LiveKit JWTs (signed by lk-jwt with the API secret).
- **Docker** isolates containers. Synapse can reach lk-jwt on the bridge; other containers can't reach either unless on the same bridge.

### What's NOT protected

- **Loopback-bound ports** (8008, 8081) are only reachable from the host. If an attacker gets shell on the host, they can reach these. But if they have shell, they have the whole system anyway.
- **`network_mode: host` on LiveKit** means LiveKit's ports (7880, 7881, 3479, 50000-50020, 50300-50310) bind directly to host interfaces. Firewall (UFW) must block anything not meant to be external.
- **Docker's iptables** can bypass UFW for container-published ports. For this stack, only lk-jwt's loopback/bridge ports are published, which is safe.

Full port and firewall reference: [`PORTS-AND-FIREWALL.md`](PORTS-AND-FIREWALL.md)

---

## Design decisions

Why the stack is configured the way it is.

### Why no coturn

Earlier versions of this stack used coturn for legacy 1:1 calls (`m.call.*`). It was removed because:

1. **Element is deprecating legacy calling.** The new stack (Element Call) uses MatrixRTC.
2. **Element X dropped legacy support entirely.** Legacy calls can't reach it.
3. **In a mixed environment (iPhone + desktop), legacy calls are useless.** Only MatrixRTC works for all clients.
4. **LiveKit's embedded TURN handles MatrixRTC relay.** No separate TURN server needed.

Removing coturn frees ~22 router rules and removes a service that can fail and take calls down.

If you ever need legacy calls, coturn can be added back — but it's not worth the complexity for most deployments.

### Why VP8 + H264 + Opus (no VP9/AV1)

LiveKit's `enabled_codecs` is restricted to VP8, H264, and Opus.

**VP9 and AV1 are excluded** because they trigger `dependencyDescriptorExtID mismatch` on LiveKit 1.13.11 when clients use different SDKs (Rust ↔ JS).

The dependency descriptor extension is used differently by VP9/AV1 (for every frame) vs VP8 (only for simulcast layers). When the JS SDK and Rust SDK assign different extension IDs, LiveKit can't bridge the media streams.

VP8 + H264 + Opus works reliably across all client combinations. If a future LiveKit version fixes the extension ID negotiation, VP9/AV1 can be re-enabled.

### Why no static Caddy handler for `/rtc/transports`

Earlier versions of this stack had a static Caddy handler for `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports`. This broke cross-client calls because:

1. The endpoint requires authentication — clients send an access token
2. A static Caddy response bypasses Synapse entirely
3. Clients got the JSON but never completed the MatrixRTC handshake
4. Result: calls rang but never connected (especially Rust ↔ JS)

**The fix:** remove the static handler. Let Synapse serve the endpoint natively (with auth). This requires `matrix_rtc.transports` in `homeserver.yaml` and `msc4143_enabled: true` in `experimental_features`.

Verify: `curl -i https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` should return `HTTP/2 401` (correct — needs auth). An authenticated client gets `200` with the JSON.

### Why `advertise_internal_ip: true` on LiveKit

Without it, LiveKit advertises only the public IP in ICE candidates. LAN clients must route through the router and back (NAT hairpin), which some routers handle poorly.

With `advertise_internal_ip: true`, LiveKit also advertises the LAN IP. LAN clients use the direct LAN path, avoiding hairpin entirely. External clients still use the public IP.

### Why `Type=oneshot` for systemd units

The systemd units use:

```ini
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose up -d
```

This means:

- `docker compose up -d` runs once (at boot), then exits
- systemd marks the service "active" (via `RemainAfterExit=yes`)
- Docker's `restart: always` handles container crashes
- Manual `docker compose restart <service>` works without fighting systemd

The alternative (`Type=simple` with foreground `up`) means systemd supervises the compose process. That's more fragile — manual container restarts can conflict with systemd's supervision.

## Glossary

| Term | Meaning |
|---|---|
| **Federation** | How Matrix servers talk to each other. When you message a user on matrix.org, your server federates with theirs. |
| **Homeserver** | A Matrix server. Yours is one. matrix.org is another. |
| **Signing key** | Your homeserver's cryptographic identity. Signs every federated event so other servers can verify it came from you. |
| **Room** | A conversation in Matrix (group chat, DM, video room). |
| **MSC** | Matrix Spec Change — a proposal for a new feature. MSC4143 is the MatrixRTC spec. MSC4195 is the LiveKit transport spec. |
| **AS / Application Service** | A service that registers with Synapse and acts as a special user. lk-jwt uses this to verify room membership. |
| **SFU** | Selective Forwarding Unit — routes media streams between participants. LiveKit is the SFU in this stack. |
| **TURN** | Traversal Using Relays around NAT — a relay server that forwards WebRTC traffic when direct peer-to-peer fails. LiveKit has one embedded. |
| **MatrixRTC** | The Matrix spec for real-time communication (voice, video, screen share). Uses an SFU instead of peer-to-peer. |
| **MSC4143** | The MatrixRTC spec. Defines how clients discover and connect to the SFU. |
| **MSC4195** | The LiveKit-specific MatrixRTC spec. Defines the AS-mode token flow. |
| **MSC4140** | The delegated delayed leave spec. Lets lk-jwt clean up disconnected participants on Synapse's behalf. |
| **lk-jwt** | LiveKit JWT service — issues LiveKit tokens for Matrix users, verifies room membership via AS mode. |
| **LiveKit** | The SFU that routes media in this stack. |
| **Caddy** | The reverse proxy that handles HTTPS, routing, and automatic Let's Encrypt certificates. |

---

## See also

- [`INSTALL.md`](INSTALL.md) — installation walkthrough
- [`CONFIGURATION.md`](CONFIGURATION.md) — every config file explained
- [`PORTS-AND-FIREWALL.md`](PORTS-AND-FIREWALL.md) — port map and UFW
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures
- [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md) — backup and restore
- [`FEDERATION.md`](FEDERATION.md) — federation setup
