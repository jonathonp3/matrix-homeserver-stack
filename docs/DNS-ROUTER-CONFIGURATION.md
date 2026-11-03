# DNS, Router, and UFW Configuration

Short guide to making your Matrix server reachable from the internet.

**Three steps:** NameSilo DNS → router port forwards → UFW. Then install Docker and Caddy on the Pi.

---

## 1. NameSilo DNS Setup

You need **two** A records pointing at your **public IP** (the same IP your DDNS script updates).

### Add the records

1. Log into NameSilo → **Domain Manager**
2. Click the **blue globe icon** next to your domain (opens DNS Manager)
3. Under "Add/Edit a Resource Record", select **A**
4. Add these two records:

| Hostname | IPv4 Address | TTL |
|---|---|---|
| `matrix` | `<your public IP>` | 3600 |
| `@` (or leave blank) | `<your public IP>` | 3600 |

- `matrix` → creates `matrix.example.com` (your Matrix homeserver)
- `@` → creates `example.com` (apex domain, used for `.well-known` discovery)

**Why both?** Matrix clients and federated servers check `https://example.com/.well-known/matrix/client` to find your homeserver. The apex domain must resolve so that endpoint works. If you only set `matrix`, federation and client discovery fail.

### Verify

```bash
dig +short matrix.example.com    # → your public IP
dig +short example.com           # → your public IP
```

--

## 2. Router Port Forwarding

Forward these ports to your Pi’s LAN IP (for example, `192.168.1.100`):

| Service | External Port | Internal Port | Internal IP | Protocol |
|---|---:|---:|---|---|
| HTTP | 80 | 80 | `<Pi LAN IP>` | TCP |
| HTTPS | 443 | 443 | `<Pi LAN IP>` | TCP |

Why 80? Caddy uses port 80 for the Let's Encrypt ACME challenge (proving you own the domain). Without it, Caddy can't get a certificate.

Why 443? All actual traffic (Matrix, LiveKit signaling, lk-jwt) goes over HTTPS on 443.

No other ports needed for this guide — the LiveKit media ports (3479, 50000–50020, 50300–50310) are separate and documented in PORTS-AND-FIREWALL.md.

--

## 3. UFW (Host Firewall)

Allow the same two ports on the Pi itself.

```bash
sudo ufw allow 80/tcp comment 'Caddy HTTP'
sudo ufw allow 443/tcp comment 'Caddy HTTPS'
sudo ufw reload
sudo ufw status verbose
```

Expected output shows both ALLOW IN.

Important: If you haven't already allowed SSH (port 22), do it before enabling UFW:

```bash
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw enable
```
Without this, you'll lock yourself out of the Pi.

--

## 4. Install Docker and Caddy on the Pi

Now that DNS and ports are ready, install Docker and Caddy on the Pi.
Run the installation script

```bash
# Clone the repo (if you haven't already)
git clone https://github.com/jonathonp3/matrix-homeserver-stack.git
cd matrix-homeserver-stack

# Make the script executable
chmod +x scripts/install_docker_caddy.sh

# Run it
./scripts/install_docker_caddy.sh
```

--

The script:

    Removes any stale Docker repo config

    Adds the official Docker GPG key and repository

    Installs Docker CE, Docker Compose plugin, and containerd

    Adds your user to the docker group

    Adds the official Caddy GPG key and repository

    Installs Caddy

    Prints the installed versions

See scripts/install_docker_caddy.sh for the full script.
After the script runs

Log out and back in (or reboot) so the docker group change takes effect:

```bash
# Log out, log back in
# Verify
groups | grep docker
# → docker
```

Verify Docker

```bash
docker --version
docker compose version
docker run --rm hello-world
```

Expected: "Hello from Docker!" — confirms Docker is working.
Verify Caddy

```bash
caddy version
sudo systemctl status caddy
```
Expected: Active: active (running).

Caddy is running with the default config (a placeholder page on port 80). It will fail to serve your Matrix domain until you copy caddy/Caddyfile.example to /etc/caddy/Caddyfile and replace the placeholders.

--

## 5. Order of Operations

    DNS first — add both A records in NameSilo, wait for propagation

    Router second — forward 80 and 443 to the Pi

    UFW third — allow 80 and 443 on the Pi

    Install Docker + Caddy — run scripts/install_docker_caddy.sh

    Deploy the Caddyfile — copy caddy/Caddyfile.example to /etc/caddy/Caddyfile, replace matrix.example.com and example.com with your real domain, reload Caddy:

```bash
sudo cp caddy/Caddyfile.example /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile    # replace example.com with your domain
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```
If you do Caddy before DNS is ready, it will fail to get a certificate and log errors. It retries, so it'll eventually work once DNS propagates — but cleaner to do DNS first.
Quick Verification (from outside your LAN)

```bash
# DNS resolves
dig +short matrix.example.com

# HTTPS works (after Caddy is configured)
curl -sI https://matrix.example.com/_matrix/client/versions | head -1
# → HTTP/2 200

# HTTP redirects to HTTPS (Caddy default)
curl -sI http://matrix.example.com | head -1
# → HTTP/1.1 308 Permanent Redirect
```

If DNS resolves but HTTPS fails, check:

    Router forward for 443 is correct

    UFW allows 443

    Caddy is running (sudo systemctl status caddy)

    Caddyfile has the correct domain (no example.com left in it)

See also

    PORTS-AND-FIREWALL.md — full port reference and UFW for the Matrix stack

    INSTALL.md — full installation walkthrough after DNS/ports are ready

    ../scripts/install_docker_caddy.sh — Docker + Caddy install script

    ../scripts/update_domain.sh — NameSilo DDNS update script




