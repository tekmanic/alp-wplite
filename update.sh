#!/bin/bash
# update.sh — roll alp-wplite forward to the latest stable WordPress.
#
# What it does:
#   1. Query wordpress.org for the latest stable version.
#   2. If it's newer than the running image, download the tarball, compute its
#      sha1, and rebuild the image with --build-arg WPLITE_VERSION/WPLITE_SHA1.
#   3. Recreate the container, preserving the wp-content named volume (which holds
#      the SQLite DB, themes, plugins, and uploads).
#   4. Wait for the site to come up and verify it responds.
#
# Idempotent: safe to run repeatedly. If already current, it only recreates the
# container (no rebuild) and verifies health.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="alp-wplite:latest"
CONTAINER="alp-wplite"
VOLUME="wplite-content"
PORT="${PORT:-8081}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# --- 1. Latest stable WordPress version -------------------------------------
log "Querying wordpress.org for the latest stable version..."
latest="$(python3 - <<'PY'
import json, urllib.request
req = urllib.request.Request(
    "https://api.wordpress.org/core/version-check/1.7/",
    headers={"User-Agent": "sentinel/1.0"})
with urllib.request.urlopen(req, timeout=30) as r:
    print(json.load(r)["offers"][0]["version"])
PY
)"
log "Latest WordPress: ${latest}"

# --- 2. Current image version -----------------------------------------------
current="$(docker inspect --format '{{index .Config.Labels "version"}}' "${IMAGE}" 2>/dev/null || echo 'unknown')"
log "Current image version: ${current}"

if [[ "${latest}" == "${current}" ]]; then
    log "Already up to date (${latest}). No rebuild needed."
else
    log "Newer version available (${current} -> ${latest}). Rebuilding image..."
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    # Download the tarball and compute its sha1 in one pass.
    sha1="$(python3 - "${tmp}" "${latest}" <<'PY'
import hashlib, sys, urllib.request
tmp, ver = sys.argv[1], sys.argv[2]
url = f"https://wordpress.org/wordpress-{ver}.tar.gz"
req = urllib.request.Request(url, headers={"User-Agent": "sentinel/1.0"})
h = hashlib.sha1()
with urllib.request.urlopen(req, timeout=300) as r, open(f"{tmp}/wp.tar.gz", "wb") as f:
    while True:
        c = r.read(1 << 16)
        if not c:
            break
        h.update(c)
        f.write(c)
print(h.hexdigest())
PY
)"
    log "Computed sha1: ${sha1}"
    log "Building ${IMAGE} with WPLITE_VERSION=${latest} ..."
    docker build \
        --build-arg WPLITE_VERSION="${latest}" \
        --build-arg WPLITE_SHA1="${sha1}" \
        -t "${IMAGE}" "${REPO_DIR}"
fi

# --- 3. Recreate the container (preserving the volume) ----------------------
log "Recreating container ${CONTAINER} (volume ${VOLUME} preserved)..."
docker stop "${CONTAINER}" 2>/dev/null || true
docker rm -f "${CONTAINER}" 2>/dev/null || true
docker run -d \
    --net="bridge" \
    --name="${CONTAINER}" \
    -p "${PORT}:80" \
    -e SERVER_NAME=localhost \
    -e URL="http://localhost:${PORT}" \
    -e ADMIN_NAME=admin \
    -e ADMIN_EMAIL=admin@domain.com \
    -e TITLE='alp-wplite' \
    -e THEME=twentytwentyfour \
    -v "${VOLUME}:/usr/src/wordpress/wp-content" \
    "${IMAGE}"

# --- 4. Wait for health and verify ------------------------------------------
log "Waiting for the site to come up on :${PORT}..."
ok=0
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then
        ok=1
        break
    fi
    sleep 5
done

if [[ "${ok}" -eq 1 ]]; then
    live="$(docker inspect --format '{{index .Config.Labels "version"}}' "${IMAGE}" 2>/dev/null || echo '?')"
    log "OK: alp-wplite is up to date (WordPress ${live}). Site responding on :${PORT}."
else
    log "ERROR: site did not respond on :${PORT} after 300s. Check 'docker logs ${CONTAINER}'."
    exit 1
fi
