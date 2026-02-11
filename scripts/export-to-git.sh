#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: export_to_git.sh <WORKFLOW_ID>}"

DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev-n8n-dev-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/workflows"
TMP_DIR="/tmp/n8n-export-${WORKFLOW_ID}"

mkdir -p "$OUT_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

echo "[1] Export workflow from DEV -> container tmp"
docker exec "$DEV_CONTAINER" sh -lc "rm -rf /tmp/n8n-git && mkdir -p /tmp/n8n-git"
docker exec "$DEV_CONTAINER" n8n export:workflow --id "$WORKFLOW_ID" --output "/tmp/n8n-git/${WORKFLOW_ID}.json" --pretty

echo "[2] Copy exported file to Jenkins workspace"
docker cp "${DEV_CONTAINER}:/tmp/n8n-git/${WORKFLOW_ID}.json" "${TMP_DIR}/${WORKFLOW_ID}.json"

echo "[3] Normalize JSON for cleaner diffs"
# keep array format (n8n export:workflow biasanya array)
jq -S '.' "${TMP_DIR}/${WORKFLOW_ID}.json" > "${OUT_DIR}/${WORKFLOW_ID}.json"

echo "[4] Done: ${OUT_DIR}/${WORKFLOW_ID}.json"
