#!/bin/bash
set -uo pipefail

# --- Configuration ---
EMAIL="jonathonpoppleton@posteo.net"
LOG_DIR="$HOME/logs"
UPDATE_LOG="$LOG_DIR/matrix_image_update.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
DATE_TAG=$(date +"%Y%m%d")

# Track overall status
OVERALL_STATUS="SUCCESS"
MESSAGES=""

# --- Helpers ---
log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$UPDATE_LOG"
}

log_section() {
    log "--- $* ---"
}

send_email() {
    local subject="$1"
    local body="$2"
    echo -e "$body" | mail -s "$subject" "$EMAIL"
    log "Email sent: $subject"
}

get_image_id() {
    local image="$1"
    docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" --no-trunc \
        | grep -F "${image} " | awk '{print $2}' || true
}

# Generic update function
# Args: name, image, workdir, systemd_unit, compose_service, health_check_cmd, health_timeout
update_service() {
    local name="$1"
    local image="$2"
    local workdir="$3"
    local systemd_unit="$4"
    local compose_service="$5"
    local health_check="$6"
    local health_timeout="${7:-60}"

    log_section "Updating $name"
    log "Image: $image"

    # Current image ID
    local old_id
    old_id=$(get_image_id "$image")
    if [ -z "$old_id" ]; then
        log "⚠️  $image not found locally — pulling fresh"
    else
        log "Current image ID: $old_id"
    fi

    # Pull latest
    log "Pulling $image ..."
    if ! docker pull "$image" >> "$UPDATE_LOG" 2>&1; then
        log "❌ Failed to pull $image"
        MESSAGES+="❌ $name: pull failed\n"
        OVERALL_STATUS="FAILURE"
        return 1
    fi

    local new_id
    new_id=$(get_image_id "$image")
    log "New image ID: $new_id"

    # No change?
    if [ "$old_id" = "$new_id" ] && [ -n "$old_id" ]; then
        log "✅ $name: no update available"
        MESSAGES+="✅ $name: no update\n"
        return 0
    fi

    # New image — tag rollback
    if [ -n "$old_id" ]; then
        local rollback_tag
        rollback_tag="rollback-${DATE_TAG}"
        log "Tagging old image as $rollback_tag"
        docker tag "$old_id" "${image%:*}:${rollback_tag}" 2>/dev/null || true
    fi

    # Restart only the specific service in the compose project
    log "Recreating $compose_service via docker compose ..."
    if ! (cd "$workdir" && docker compose up -d --force-recreate "$compose_service" >> "$UPDATE_LOG" 2>&1); then
        log "❌ Failed to recreate $compose_service"
        MESSAGES+="❌ $name: recreate failed\n"
        OVERALL_STATUS="FAILURE"
        return 1
    fi

    # Health check
    log "Waiting for $name health (up to ${health_timeout}s) ..."
    local waited=0
    while [ $waited -lt "$health_timeout" ]; do
        if eval "$health_check" > /dev/null 2>&1; then
            log "✅ $name: healthy after ${waited}s"
            MESSAGES+="✅ $name: updated ${old_id:0:12} → ${new_id:0:12}\n"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done

    log "❌ $name: health check timeout after ${health_timeout}s"
    MESSAGES+="❌ $name: health check failed (rollback tag: $rollback_tag)\n"
    OVERALL_STATUS="FAILURE"
    return 1
}

# --- Main ---
mkdir -p "$LOG_DIR"
log "=========================================="
log "Matrix stack image update — $TIMESTAMP"
log "=========================================="

# 1. Synapse (DB migrations — allow 120s for health)
update_service \
    "Synapse" \
    "ghcr.io/element-hq/synapse:latest" \
    "$HOME/matrix" \
    "synapse-compose.service" \
    "synapse" \
    "curl -sf -o /dev/null -w '%{http_code}' https://matrix.cloud-blue.top/_matrix/client/versions | grep -q 200" \
    120

# 2. lk-jwt (no DB, fast startup)
update_service \
    "lk-jwt" \
    "ghcr.io/element-hq/lk-jwt-service:latest" \
    "$HOME/matrix/rtc" \
    "rtc-compose.service" \
    "lk-jwt" \
    "curl -sf -o /dev/null -w '%{http_code}' https://matrix.cloud-blue.top/livekit/jwt/healthz | grep -q 200" \
    60

# 3. LiveKit (SFU, brief restart kills calls)
update_service \
    "LiveKit" \
    "livekit/livekit-server:latest" \
    "$HOME/matrix/rtc" \
    "rtc-compose.service" \
    "livekit" \
    "curl -sf -o /dev/null -w '%{http_code}' https://matrix.cloud-blue.top/livekit/sfu/ | grep -q 200" \
    60

# --- Summary ---
log "=========================================="
log "Update complete — overall: $OVERALL_STATUS"
log "=========================================="

# Email summary
SUBJECT="Matrix image update — $OVERALL_STATUS ($TIMESTAMP)"
BODY="Matrix image update report\n"
BODY+="Time: $TIMESTAMP\n"
BODY+="Host: $(hostname)\n"
BODY+="Overall: $OVERALL_STATUS\n\n"
BODY+="Actions:\n$MESSAGES"
BODY+="\nFull log: $UPDATE_LOG"

send_email "$SUBJECT" "$BODY"

[ "$OVERALL_STATUS" = "SUCCESS" ] && exit 0 || exit 1
