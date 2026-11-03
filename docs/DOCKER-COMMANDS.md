# Docker Commands Reference

Practical commands for managing the `matrix-homeserver-stack` containers. Copy-paste ready for common tasks.

**Convention:** all commands assume you're in the right directory unless noted. The stack has two compose projects:

- `~/matrix/` — Synapse
- `~/matrix/rtc/` — LiveKit + lk-jwt

---

## Quick reference

| Task | Command |
|---|---|
| See what's running | `docker ps` |
| See all containers (including stopped) | `docker ps -a` |
| Follow logs for one container | `docker logs -f <name>` |
| Restart one container | `docker compose restart <service>` |
| Recreate one container (config change) | `docker compose up -d --force-recreate <service>` |
| Stop everything in a project | `docker compose down` |
| Start everything in a project | `docker compose up -d` |
| Pull latest images | `docker compose pull` |
| Check resource usage | `docker stats` |

---

## Part 1 — Understanding the layout

### 1.1 Compose projects

```text
~/matrix/
├── docker-compose.yml        ← project: "matrix"
│   └── service: synapse
└── data/

~/matrix/rtc/
├── docker-compose.yml        ← project: "rtc"
│   ├── service: livekit
│   └── service: lk-jwt
├── livekit/
└── lk-jwt/
```

Each directory with a `docker-compose.yml` is its own **project**. Commands like `docker compose restart` operate on one project at a time.

### 1.2 Container names vs service names

| Container name | Service name | Compose project |
|---|---|---|
| `synapse` | `synapse` | `matrix` |
| `livekit` | `livekit` | `rtc` |
| `lk-jwt` | `lk-jwt` | `rtc` |

Container names are set explicitly in the compose file (`container_name: synapse`). Service names are the keys under `services:`. For `docker compose` commands, use **service names**. For `docker` commands, use **container names**.

Both happen to be identical in this stack — no confusion.

---

## Part 2 — Viewing state

### 2.1 What's running?

```bash
docker ps
```

Output:

```text
CONTAINER ID   IMAGE                                ...   NAMES
abc123...      ghcr.io/element-hq/synapse:latest    ...   synapse
def456...      livekit/livekit-server:latest        ...   livekit
ghi789...      ghcr.io/element-hq/lk-jwt-service... ...   lk-jwt
```

### 2.2 What's running, with health status?

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
```

Output:

```text
NAMES     STATUS                    IMAGE
synapse   Up 2 hours (healthy)      ghcr.io/element-hq/synapse:latest
livekit   Up 2 hours                livekit/livekit-server:latest
lk-jwt    Up 2 hours (healthy)      ghcr.io/element-hq/lk-jwt-service:latest
```

The `(healthy)` suffix means the container's `HEALTHCHECK` is passing. `synapse` and `lk-jwt` have healthchecks defined in their images; `livekit` doesn't.

### 2.3 All containers including stopped

```bash
docker ps -a
```

### 2.4 Which compose projects exist?

```bash
docker compose ls
```

Output:

```text
NAME                STATUS              CONFIG FILES
matrix              running(1)          /home/jonathon/matrix/docker-compose.yml
rtc                 running(2)          /home/jonathon/matrix/rtc/docker-compose.yml
```

### 2.5 What ports is each container using?

```bash
# Docker-managed port mappings (Synapse, lk-jwt)
docker ps --format 'table {{.Names}}\t{{.Ports}}'

# Host ports (LiveKit uses network_mode: host)
sudo ss -tlnp | grep -E ':(80|443|3479|7880|7881|8008|8081) '
sudo ss -ulnp | grep -E ':(3479|5000[0-9]|5001[0-9]|50020|5030[0-9]|50310) '
```

---

## Part 3 — Logs

### 3.1 Follow logs in real time

```bash
# Synapse
docker logs -f synapse

# LiveKit
docker logs -f livekit

# lk-jwt
docker logs -f lk-jwt
```

Press `Ctrl+C` to stop following.

### 3.2 Last N lines

```bash
docker logs --tail 50 synapse
docker logs --tail 50 livekit
docker logs --tail 50 lk-jwt
```

### 3.3 Logs since a specific time

```bash
docker logs --since 1h synapse       # last hour
docker logs --since 30m livekit      # last 30 minutes
docker logs --since 2026-11-02T10:00:00 synapse
```

### 3.4 Logs with timestamps

```bash
docker logs -t synapse
```

### 3.5 Filter logs (grep)

```bash
# Errors only
docker logs synapse 2>&1 | grep -iE 'error|warn|fail'

# LiveKit TURN activity
docker logs livekit 2>&1 | grep -i 'turn'

# LiveKit participant events
docker logs livekit 2>&1 | grep -iE 'participant|track'

# lk-jwt token issuance
docker logs lk-jwt 2>&1 | grep -iE 'get_token|create'

# lk-jwt errors
docker logs lk-jwt 2>&1 | grep -iE 'error'
```

### 3.6 Journald (for systemd-managed services)

If the container fails to start, systemd captures the compose output:

```bash
journalctl --user -u synapse-compose.service -n 100 --no-pager
journalctl --user -u rtc-compose.service -n 100 --no-pager
journalctl --user -u rtc-compose.service -f       # follow
```

---

## Part 4 — Restarting and recreating

### 4.1 The difference

| Action | What it does | When to use |
|---|---|---|
| **Restart** | Stops and starts the same container | Transient issue; clear in-memory state |
| **Recreate** | Replaces the container using the same image and configuration | Configuration changed, or the container is in a bad state |
| **Rebuild** | Creates a new image, then recreates the container from it | The image or build inputs changed (e.g., you pulled a new version) |

### 4.2 Restart a single container

```bash
# Method 1: docker compose (recommended — respects compose config)
cd ~/matrix/rtc
docker compose restart livekit

# Method 2: docker directly (same effect)
docker restart livekit
```

**When to use:** the container is running but misbehaving. **Not** for config changes (restart doesn't re-read config files).

### 4.3 Recreate a single container (after config change)

```bash
# Synapse (config in ~/matrix/data/homeserver.yaml)
cd ~/matrix
docker compose up -d --force-recreate synapse

# LiveKit (config in ~/matrix/rtc/livekit/livekit.yaml)
cd ~/matrix/rtc
docker compose up -d --force-recreate livekit

# lk-jwt (config in ~/matrix/rtc/lk-jwt/.env)
cd ~/matrix/rtc
docker compose up -d --force-recreate lk-jwt
```

**When to use:** you edited a mounted **config file** and need the container to **re-read** it.

`--force-recreate` destroys the existing container and creates a new one. Other containers in the same project are **not** touched. So `--force-recreate livekit` doesn't restart `lk-jwt`.

### 4.4 Restart the whole compose project

```bash
# Synapse project (1 container)
cd ~/matrix
docker compose restart

# RTC project (2 containers)
cd ~/matrix/rtc
docker compose restart
```

**When to use:** multiple containers need a restart, or you're unsure which one is the problem.

### 4.5 Stop and start (cleaner than restart)

```bash
cd ~/matrix/rtc
docker compose down
docker compose up -d
```

**When to use:** a `restart` didn't fix the issue, or you want a clean cycle. `down` removes containers (keeps volumes), `up -d` creates fresh ones.

### 4.6 Restart via systemd

```bash
systemctl --user restart synapse-compose.service
systemctl --user restart rtc-compose.service
```

**When to use:** you want to restart the whole project via systemd. This runs `ExecStop` (`docker compose down`) then `ExecStart` (`docker compose up -d`).

**Not recommended for single-container restarts** — `systemctl restart rtc-compose.service` restarts **both** livekit and lk-jwt, even if only one changed.

---

## Part 5 — Pulling updates

### 5.1 Pull latest images

```bash
# Synapse
cd ~/matrix
docker compose pull

# RTC stack
cd ~/matrix/rtc
docker compose pull
```

This downloads newer versions of the images tagged in the compose files (`:latest`).

### 5.2 See what changed

```bash
# Before pull
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}'

# Pull
cd ~/matrix && docker compose pull
cd ~/matrix/rtc && docker compose pull

# After pull
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}'
```

The image IDs should have changed if updates were available.

### 5.3 Apply the update

```bash
# Recreate only the containers whose images changed
cd ~/matrix
docker compose up -d --force-recreate synapse

cd ~/matrix/rtc
docker compose up -d --force-recreate livekit
docker compose up -d --force-recreate lk-jwt
```

**Or** use the automated script (recommended):

```bash
~/update_matrix_images.sh
```

The script pulls, compares image IDs, only recreates if changed, and emails you a summary.

### 5.4 Rollback to previous image

If an update broke something, revert:

```bash
# List available rollback tags
docker images --format '{{.Repository}}:{{.Tag}}' | grep rollback

# Example output:
# ghcr.io/element-hq/synapse:rollback-20261102

# Update the compose file to use the rollback tag
cd ~/matrix
vim docker-compose.yml
# Change: image: ghcr.io/element-hq/synapse:latest
# To:     image: ghcr.io/element-hq/synapse:rollback-20261102

# Recreate with the old image
docker compose up -d --force-recreate synapse
```

Or pull the old image by digest if you know it:

```bash
docker pull ghcr.io/element-hq/synapse@sha256:3c2900775df2...
```

---

## Part 6 — Executing commands inside containers

### 6.1 Run a command

```bash
docker exec synapse <command>
docker exec livekit <command>
docker exec lk-jwt <command>
```

### 6.2 Interactive shell

```bash
# Bash (if available)
docker exec -it synapse bash

# Sh (always available)
docker exec -it synapse sh

docker exec -it livekit sh
docker exec -it lk-jwt sh
```

### 6.3 Common debugging commands

```bash
# Synapse: check DB integrity
docker exec synapse sqlite3 /data/homeserver.db "PRAGMA integrity_check;"

# Synapse: check config was loaded
docker exec synapse python3 -c "import synapse; print(synapse.__version__)"

# Synapse: verify homeserver.yaml is valid
docker exec synapse python3 -c "import yaml; yaml.safe_load(open('/data/homeserver.yaml'))"

# LiveKit: check version
docker exec livekit livekit-server --version

# LiveKit: verify config was loaded
docker exec livekit cat /etc/livekit.yaml

# lk-jwt: check environment
docker exec lk-jwt sh -c 'cat /proc/1/environ | tr "\0" "\n" | grep LIVEKIT'
```

### 6.4 Execute without a shell (for scripting)

```bash
# Synapse: check DB
docker exec synapse sqlite3 /data/homeserver.db "SELECT COUNT(*) FROM users;"

# lk-jwt: verify it's listening
docker exec lk-jwt wget -qO- http://127.0.0.1:8080/healthz 2>/dev/null
```

---

## Part 7 — Inspecting containers

### 7.1 Full details (JSON)

```bash
docker inspect synapse
docker inspect livekit
docker inspect lk-jwt
```

### 7.2 Filtered output

```bash
# Health status
docker inspect synapse --format '{{json .State.Health}}' | python3 -m json.tool

# Container state
docker inspect synapse --format '{{.State.Status}}'
# → running

# Started at
docker inspect synapse --format '{{.State.StartedAt}}'

# Mounts
docker inspect synapse --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'

# Extra hosts (needed for AS proxy)
docker inspect synapse --format '{{json .HostConfig.ExtraHosts}}'
# → ["host.docker.internal:host-gateway"]

# Port bindings
docker inspect synapse --format '{{json .NetworkSettings.Ports}}' | python3 -m json.tool

# Environment variables
docker inspect synapse --format '{{json .Config.Env}}' | python3 -m json.tool
```

### 7.3 Size and resource usage

```bash
# Real-time stats
docker stats

# One-shot stats
docker stats --no-stream

# Disk usage per image
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'

# Disk usage per volume
docker volume ls
docker system df
```

---

## Part 8 — Cleaning up

### 8.1 Remove stopped containers

```bash
docker container prune
```

### 8.2 Remove unused images

```bash
# Interactive (asks for confirmation)
docker image prune

# Force (no confirmation)
docker image prune -f

# Remove images not used by any container (aggressive)
docker image prune -a -f
```

### 8.3 Remove old rollback tags

The update script tags old images as `rollback-YYYYMMDD`. Over time these accumulate:

```bash
# List rollback tags
docker images --format '{{.Repository}}:{{.Tag}}' | grep rollback

# Remove all rollback tags
docker images --format '{{.Repository}}:{{.Tag}}' | grep rollback | xargs -r docker rmi

# Remove only rollback tags older than 30 days (safer)
docker images --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' | grep rollback | \
    awk -v cutoff="$(date -d '30 days ago' +%Y-%m-%d)" '$2 < cutoff {print $1}' | \
    xargs -r docker rmi
```

### 8.4 Remove all unused data

```bash
# Removes: stopped containers, unused networks, unused images, unused build cache
# Does NOT remove volumes (safe for your data)
docker system prune

# Also removes volumes (⚠️ DANGEROUS — will delete unused volumes)
# docker system prune --volumes
```

**Don't use `--volumes`** in this stack — you use bind mounts, not named volumes, so it shouldn't matter. But be careful.

### 8.5 Check disk usage

```bash
docker system df
```

Output:

```text
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          8         3         2.1GB     1.2GB (57%)
Containers      3         3         45MB      0B (0%)
Local Volumes   0         0         0B        0B
Build Cache     0         0         0B        0B
```

If `RECLAIMABLE` is high, `docker image prune` will free space.

---

## Part 9 — Networks

### 9.1 List networks

```bash
docker network ls
```

Output:

```text
NETWORK ID     NAME           DRIVER    SCOPE
abc123...      bridge         bridge    local
def456...      host           host      local
ghi789...      matrix_default bridge    local
jkl012...      rtc_default    bridge    local
```

### 9.2 Inspect a network

```bash
docker network inspect rtc_default
```

Shows which containers are on the network, their IPs, and the gateway.

### 9.3 Why it matters

- `synapse` is on `matrix_default`
- `livekit` is on `host` network (not a bridge network)
- `lk-jwt` is on `rtc_default`

The `172.17.0.1` address in the AS registration points at the `docker0` bridge (default), which is where lk-jwt's second port binding lands (`172.17.0.1:8081:8080`).

---

## Part 10 — Common scenarios

### 10.1 "I edited homeserver.yaml and nothing changed"

```bash
cd ~/matrix
docker compose up -d --force-recreate synapse
```

`restart` doesn't re-read mounted config files. You need `--force-recreate`.

### 10.2 "I edited livekit.yaml and nothing changed"

```bash
cd ~/matrix/rtc
docker compose up -d --force-recreate livekit
```

Same reason — `restart` doesn't re-read the mounted config.

### 10.3 "I edited lk-jwt/.env and nothing changed"

```bash
cd ~/matrix/rtc
docker compose up -d --force-recreate lk-jwt
```

`env_file` is read at container creation, not restart.

### 10.4 "Calls stopped working after a restart"

Check if LiveKit is running:

```bash
docker ps --filter name=livekit
docker logs livekit --tail 20
```

Common causes:

- Config syntax error (YAML parse failure)
- Missing keys in `livekit.yaml` (see the `keys:` block)
- Port conflict (something else on 3479 or 7880)

### 10.5 "Synapse won't start after update"

```bash
docker logs synapse --tail 50
```

Look for:

- Database migration error → wait for it to complete (can take minutes)
- Config parse error → `docker exec synapse python3 -c "import yaml; yaml.safe_load(open('/data/homeserver.yaml'))"`
- Permission error → `sudo chown -R 991:render ~/matrix/data/`

### 10.6 "Everything is broken, let's start fresh"

```bash
# Stop everything
systemctl --user stop synapse-compose.service rtc-compose.service

# Clean up containers (keeps volumes and bind mounts)
cd ~/matrix && docker compose down
cd ~/matrix/rtc && docker compose down

# Pull latest
cd ~/matrix && docker compose pull
cd ~/matrix/rtc && docker compose pull

# Start
systemctl --user start synapse-compose.service
sleep 20
systemctl --user start rtc-compose.service
sleep 15

# Verify
docker ps
curl -s https://matrix.example.com/_matrix/client/versions | head -c 60
```

### 10.7 "I want to see what a container is doing right now"

```bash
# Real-time logs
docker logs -f livekit

# Real-time resource usage
docker stats livekit

# Process list inside the container
docker exec livekit ps aux

# Network connections
docker exec livekit ss -tlnp
```

---

## Part 11 — Systemd vs Docker

The containers are managed by systemd user services, which run `docker compose` at boot. Understanding the relationship:

### 11.1 At boot

```text
systemd (user) → synapse-compose.service → docker compose up -d → synapse container
systemd (user) → rtc-compose.service     → docker compose up -d → livekit + lk-jwt containers
```

### 11.2 At shutdown

```text
systemd (user) → synapse-compose.service → docker compose down → synapse stops
systemd (user) → rtc-compose.service     → docker compose down → livekit + lk-jwt stop
```

### 11.3 What you can do directly

| Command | Effect | Conflicts with systemd? |
|---|---|---|
| `docker restart synapse` | Restart container | No (systemd doesn't supervise containers) |
| `docker compose restart livekit` | Restart container | No |
| `docker compose up -d --force-recreate livekit` | Recreate container | No |
| `docker compose down` | Stop all containers in the project | systemd still thinks the service is "active" |
| `systemctl --user restart rtc-compose.service` | Down + up the whole project | Runs systemd's `ExecStop` + `ExecStart` |

**Key insight:** with `Type=oneshot` + `RemainAfterExit=yes`, systemd runs `docker compose up -d` once and considers the service "active". It does **not** supervise the running containers. So:

- Manual container operations work freely
- Docker's `restart: always` handles container crashes
- systemd only intervenes if you explicitly `systemctl restart/stop`

### 11.4 If you stop containers manually, does systemd notice?

```bash
docker compose down       # containers stopped
systemctl --user status rtc-compose.service
# → Active: active (exited) — still shows "active"
```

systemd's state is "the `docker compose up -d` command completed successfully", not "the containers are running". So `down` doesn't flip systemd to inactive.

To make systemd stop too:

```bash
systemctl --user stop rtc-compose.service
```

To bring it back:

```bash
systemctl --user start rtc-compose.service
```

Or:

```bash
systemctl --user restart rtc-compose.service
```

---

## Part 12 — Quick reference card

Copy-paste ready:

```bash
# ===== Status =====
docker ps                                              # running containers
docker ps -a                                           # all containers
docker compose ls                                      # compose projects
docker stats --no-stream                               # resource usage
docker system df                                       # disk usage

# ===== Logs =====
docker logs -f synapse                                 # follow logs
docker logs --tail 50 livekit                          # last 50 lines
docker logs --since 1h lk-jwt                          # last hour

# ===== Restart =====
cd ~/matrix/rtc && docker compose restart livekit      # restart one
cd ~/matrix/rtc && docker compose restart              # restart both RTC
cd ~/matrix && docker compose restart                  # restart Synapse

# ===== Recreate (after config change) =====
cd ~/matrix && docker compose up -d --force-recreate synapse
cd ~/matrix/rtc && docker compose up -d --force-recreate livekit
cd ~/matrix/rtc && docker compose up -d --force-recreate lk-jwt

# ===== Update =====
cd ~/matrix && docker compose pull && docker compose up -d --force-recreate
cd ~/matrix/rtc && docker compose pull && docker compose up -d --force-recreate
~/update_matrix_images.sh                              # automated

# ===== Cleanup =====
docker image prune -f                                  # unused images
docker container prune -f                              # stopped containers
docker images | grep rollback | awk '{print $1":"$2}' | xargs docker rmi  # old rollbacks

# ===== Debug =====
docker exec -it synapse bash                           # shell
docker exec synapse sqlite3 /data/homeserver.db "PRAGMA integrity_check;"
docker exec livekit cat /etc/livekit.yaml
docker exec lk-jwt sh -c 'cat /proc/1/environ | tr "\0" "\n"'

# ===== Systemd =====
systemctl --user status synapse-compose.service
systemctl --user restart synapse-compose.service
systemctl --user restart rtc-compose.service
journalctl --user -u rtc-compose.service -n 100
```

---

## See also

- [`PORTS-AND-FIREWALL.md`](PORTS-AND-FIREWALL.md) — port reference
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common failures
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — how the components fit
- [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md) — backup and restore
