
# Router Port Forwarding Checklist

Quick checklist of router port forwards required for `matrix-homeserver-stack`. See [`../docs/PORTS-AND-FIREWALL.md`](../docs/PORTS-AND-FIREWALL.md) for full details.

## Required forwards

All forwards target the **internal IP of the host** running the stack (e.g., `192.168.1.100`).

| Service | External | Internal | Protocol | Purpose |
|---|---|---|---|---|
| HTTP | 80 | 80 | TCP | Caddy (ACME + redirect) |
| HTTPS | 443 | 443 | TCP | Caddy (TLS) |
| LiveKit-TURN | 3479 | 3479 | UDP | LiveKit embedded TURN control |
| LiveKit-TCP | 7881 | 7881 | TCP | LiveKit TCP media fallback |
| LiveKit-UDP-01..21 | 50000-50020 | 50000-50020 | UDP | LiveKit direct media (21 rules) |
| Turn-Relay-01..11 | 50300-50310 | 50300-50310 | UDP | LiveKit TURN relay (11 rules) |

**Total: 36 rules** (or ~5 if your router supports port ranges).

## If your router supports port ranges

Enter the ranges directly:

```text
50000-50020  UDP  →  <internal IP>
50300-50310  UDP  →  <internal IP>

Reduces 36 rules to 5:

    80 (TCP)

    443 (TCP)

    3479 (UDP)

    50000-50020 (UDP)

    50300-50310 (UDP)

    7881 (TCP)

What NOT to forward

If you're coming from an older setup, these are not required:

    3478 (TCP/UDP) — legacy coturn

    5349 (TCP/UDP) — legacy TURN/TLS

  49152-49171 (UDP) — legacy coturn relay
```

See ../docs/PORTS-AND-FIREWALL.md Part 6 for why coturn was removed.
Verify

After configuring forwards, test from outside your LAN:

```bash

# HTTPS
curl -sI https://matrix.example.com/_matrix/client/versions | head -1
# → HTTP/2 200

# LiveKit UDP (requires nc)
nc -u -zv matrix.example.com 3479
nc -u -zv matrix.example.com 50000
nc -u -zv matrix.example.com 50300
# → connected
```
See also

    ../docs/PORTS-AND-FIREWALL.md — full reference

    ../docs/DNS-ROUTER-CONFIGURATION.md — DNS and router setup

