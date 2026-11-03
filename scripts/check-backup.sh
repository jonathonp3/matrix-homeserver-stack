#!/bin/bash
set -uo pipefail

# Find the newest archive (prefer unencrypted, fall back to encrypted)
ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
    ARCHIVE=$(ls -t ~/backups/matrix/matrix-backup-*.tar.gz 2>/dev/null | head -1)
    if [ -z "$ARCHIVE" ]; then
        ARCHIVE=$(ls -t ~/backups/matrix/matrix-backup-*.tar.gz.gpg 2>/dev/null | head -1)
    fi
fi
if [ -z "$ARCHIVE" ]; then
    echo "❌ No backup found"
    exit 1
fi

echo "Checking: $ARCHIVE"
echo

# 1. Checksum
echo "==> Checksum"
if [ -f "$ARCHIVE.sha256" ]; then
    EXPECTED=$(cut -d' ' -f1 "$ARCHIVE.sha256")
    ACTUAL=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        echo "✓ Checksum: $ACTUAL"
    else
        echo "❌ Checksum mismatch"
        echo "  Expected: $EXPECTED"
        echo "  Actual:   $ACTUAL"
        exit 1
    fi
else
    echo "⚠️ No .sha256 file found"
fi
echo

# 2. Extract (if encrypted) or use tar directly
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ "$ARCHIVE" == *.gpg ]]; then
    echo "==> Decrypting..."
    gpg -d "$ARCHIVE" | tar -xzf - -C "$TMP" || exit 1
else
    echo "==> Extracting..."
    tar -xzf "$ARCHIVE" -C "$TMP" || exit 1
fi
STAGE_DIR="$TMP/$(ls "$TMP" | head -1)"
echo

# 3. Critical files
echo "==> Critical files"
CRITICAL=(
    "matrix/data/homeserver.db"
    "matrix/data/homeserver.yaml"
    "matrix/data/matrix.example.com.signing.key"
    "matrix/data/lk-jwt-as.yaml"
    "matrix/docker-compose.yml"
    "matrix/rtc/docker-compose.yml"
    "matrix/rtc/livekit/livekit.yaml"
    "matrix/rtc/lk-jwt/.env"
    "etc/Caddyfile"
)
FAIL=0
for f in "${CRITICAL[@]}"; do
    if [ -f "$STAGE_DIR/$f" ]; then
        echo "✓ $f"
    else
        echo "❌ MISSING: $f"
        FAIL=1
    fi
done
echo

# 4. DB integrity
echo "==> Database integrity"
if [ -f "$STAGE_DIR/matrix/data/homeserver.db" ]; then
    if command -v sqlite3 >/dev/null; then
        RESULT=$(sqlite3 "$STAGE_DIR/matrix/data/homeserver.db" "PRAGMA integrity_check;")
        if [ "$RESULT" = "ok" ]; then
            echo "✓ ok"
        else
            echo "❌ Database integrity check failed: $RESULT"
            FAIL=1
        fi
    else
        echo "⚠️ sqlite3 not installed — skipping DB check"
    fi
else
    echo "❌ homeserver.db not found"
    FAIL=1
fi
echo

# 5. Signing key
echo "==> Signing key"
KEY="$STAGE_DIR/matrix/data/matrix.example.com.signing.key"
if [ -f "$KEY" ]; then
    if head -1 "$KEY" | grep -q '^ed25519 '; then
        echo "✓ Valid ed25519 key: $(head -1 "$KEY" | cut -c1-30)..."
    else
        echo "❌ Signing key malformed"
        FAIL=1
    fi
else
    echo "❌ Signing key missing"
    FAIL=1
fi
echo

if [ $FAIL -eq 0 ]; then
    echo "✓ Backup is complete and valid"
    exit 0
else
    echo "❌ Backup has issues — re-run backup"
    exit 1
fi
