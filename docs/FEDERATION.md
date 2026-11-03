# Federation

Federation lets your Matrix homeserver talk to other homeservers. When you message a user on `matrix.org`, your server sends the event directly to their server.

This doc covers:

- What federation is (and when you need it)
- What's already configured in this stack
- How to test federation
- The signing key (your server's identity)
- Common federation issues

---

## Do you need federation?

**No, if:** your server is only used by you and your family, and nobody talks to users on other homeservers.

**Yes, if:** you want to:

- Message users on `matrix.org` or other homeservers
- Join rooms hosted on other servers
- Have friends on other servers join your rooms

Federation is **automatic** — there's no separate setup. If DNS and the signing key are correct, federation works.

---

## What's already configured

The stack includes everything needed for federation:

| Setting | Where | Value |
|---|---|---|
| `server_name` | `homeserver.yaml` | `matrix.example.com` |
| `signing_key_path` | `homeserver.yaml` | `/data/matrix.example.com.signing.key` |
| `trusted_key_servers` | `homeserver.yaml` | `matrix.org` |
| `.well-known/matrix/server` | Caddyfile | `{"m.server":"matrix.example.com:443"}` |
| `.well-known/matrix/client` | Caddyfile | `{"m.homeserver":{"base_url":"https://matrix.example.com/"}}` |
| Federation listener | Caddy | `/_matrix/federation/*` → Synapse (8008) |

Federation uses port **443** (via Caddy), not the traditional 8448. The `.well-known/matrix/server` record tells other servers to use 443.

---

## Testing federation

### The federation tester

The Matrix Federation Tester is the canonical test:

```
https://federationtester.matrix.org/#matrix.example.com
```

Replace `matrix.example.com` with your real domain.

**Expected: all green checks.**

The tester checks:

- DNS A record resolves
- TLS cert is valid
- Server responds to `/_matrix/key/v2/server`
- `server_name` matches the TLS cert
- Federation API is reachable

If any check fails, the tester tells you exactly what's wrong.

### Manual tests

```bash
# 1. Server key is published
curl -s https://matrix.example.com/_matrix/key/v2/server | python3 -m json.tool

# 2. Federation API responds
curl -sI https://matrix.example.com/_matrix/federation/v1/version | head -5

# 3. DNS + TLS work
curl -sI https://matrix.example.com | head -5
```

### Real-world test

1. Create a room on your server
2. Invite a user on another homeserver (e.g., `@someone:matrix.org`)
3. If they can join, federation works
4. If not, see "Common issues" below

---

## The signing key

`~/matrix/data/matrix.example.com.signing.key` is your homeserver's cryptographic identity.

### How it works

When your server sends an event to another server, it signs the event with this key. The receiving server:

1. Looks up your public key via `https://matrix.example.com/_matrix/key/v2/server`
2. Verifies the signature against that public key
3. Accepts the event only if the signature is valid

The private key (the signing key file) **never leaves your server**. Only the public part is published.

### What happens if you lose it

1. Your server generates a **new** signing key on startup
2. Federated servers see events signed with a different key
3. They reject those events (can't verify the signature)
4. **Federation is broken permanently** until each server manually trusts the new key

In practice, most servers never re-trust a changed signing key. Your server is effectively cut off from federation.

### Back it up

The signing key is backed up by `scripts/backup-matrix.sh` (it's in `~/matrix/data/`, which is included in the backup archive). But:

- **Always encrypt the backup.** The signing key is the most sensitive file.
- **Store it in multiple locations.** One copy isn't enough.
- **Never commit it to git.** The `.gitignore` excludes it.

If you only back up one thing, back up the signing key.

---

## Common federation issues

### Other servers reject my events

The signing key changed (or is missing). Check:

```bash
head -1 ~/matrix/data/matrix.example.com.signing.key
```

If it's missing, restore from backup. If it's different from before, federation is broken — you need to either:

1. Restore the original key from backup (best)
2. Accept that federation is broken and reconfigure remote servers to trust the new key (painful)

### Can't join federated rooms

Federation requires **bidirectional** trust. If you can't join a room on another homeserver:

1. Check your server's federation works: `https://federationtester.matrix.org/#matrix.example.com`
2. Check the other server is reachable: `curl -sI https://otherserver.example/_matrix/key/v2/server`
3. Check Synapse logs for federation errors:

```bash
docker logs synapse 2>&1 | grep -i federation | tail -20
```

### `401 Unauthorized` on federation requests

The other server can't verify your signature. Check:

- Signing key is present: `ls ~/matrix/data/*.signing.key`
- Public key is published: `curl -s https://matrix.example.com/_matrix/key/v2/server`
- The `server_name` in `homeserver.yaml` matches the domain in the TLS cert

### Federation works one-way

If you can message users on their server but they can't message you (or vice versa), it's usually:

- **Their server can't reach yours:** `curl -sI https://matrix.example.com` from their network
- **Your server can't reach theirs:** `curl -sI https://theirserver.example/_matrix/key/v2/server`
- **`.well-known` mismatch:** your `.well-known/matrix/server` returns a different server name than your TLS cert

---

## Federation policy

By default, Synapse allows federation with **all** other homeservers. You can restrict this:

### Blocklist

In `homeserver.yaml`:

```yaml
federation_domain_whitelist:
  - matrix.org
  - element.io
  - your-friends-server.example
```

This blocks **all** federation except the listed domains. Note: this is a whitelist despite the name.

### Blocklist (deny specific)

```yaml
federation_ip_range_denylist:
  - 192.0.2.0/24
  - 2001:db8::/32
```

Blocks specific IP ranges from federating. Useful for blocking known-bad servers.

---

## Federation and the signing key: the short version

- **The signing key is your server's identity.**
- **If you federate, losing it is catastrophic.**
- **Back it up, encrypted, in multiple places.**
- **Never commit it to git.**

Everything else about federation is automatic once DNS and the signing key are correct.

---

## See also

- [`INSTALL.md`](INSTALL.md) — installation walkthrough
- [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md) — the signing key is backed up by `scripts/backup-matrix.sh`
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — federation troubleshooting
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — component overview
