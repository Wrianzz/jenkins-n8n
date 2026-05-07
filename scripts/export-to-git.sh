#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: export-to-git.sh <WORKFLOW_ID> [SUB_WORKFLOW_IDS_CSV]}"
SUB_WORKFLOW_IDS_CSV="${2:-}"

DEV_SSH_HOST="${DEV_SSH_HOST:?DEV_SSH_HOST is required}"
DEV_SSH_USER="${DEV_SSH_USER:-}"
DEV_SSH_PORT="${DEV_SSH_PORT:-22}"
DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev-n8n-dev-1}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/workflows"
TMP_DIR="/tmp/n8n-export-${WORKFLOW_ID}"
LOCAL_FILE="${TMP_DIR}/${WORKFLOW_ID}.json"
REMOTE_HOST="${DEV_SSH_USER:+${DEV_SSH_USER}@}${DEV_SSH_HOST}"
SSH_OPTS=( -p "$DEV_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
if [[ -n "$SSH_KEY_FILE" ]]; then
  SSH_OPTS+=( -i "$SSH_KEY_FILE" )
fi

mkdir -p "$OUT_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

echo "[1] Export main workflow on DEV server"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' sh -lc 'rm -rf /tmp/n8n-git && mkdir -p /tmp/n8n-git && n8n export:workflow --id \"$WORKFLOW_ID\" --output /tmp/n8n-git/${WORKFLOW_ID}.json --pretty'"

echo "[2] Copy exported file from DEV server"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' cat '/tmp/n8n-git/${WORKFLOW_ID}.json'" > "$LOCAL_FILE"

echo "[3] Normalize JSON for cleaner diffs"
jq -S '.' "$LOCAL_FILE" > "${OUT_DIR}/${WORKFLOW_ID}.json"

echo "[4] Done: ${OUT_DIR}/${WORKFLOW_ID}.json"

if [[ -n "$SUB_WORKFLOW_IDS_CSV" ]]; then
  echo "[5] Export selected sub-workflow(s): $SUB_WORKFLOW_IDS_CSV"
  IFS=',' read -r -a SUB_WORKFLOW_IDS <<< "$SUB_WORKFLOW_IDS_CSV"
  for sub_id_raw in "${SUB_WORKFLOW_IDS[@]}"; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue

    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
      "docker exec '$DEV_CONTAINER' sh -lc 'n8n export:workflow --id \"$sub_id\" --output /tmp/n8n-git/${sub_id}.json --pretty'"
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
      "docker exec '$DEV_CONTAINER' cat '/tmp/n8n-git/${sub_id}.json'" > "${TMP_DIR}/${sub_id}.json"
    jq -S '.' "${TMP_DIR}/${sub_id}.json" > "${OUT_DIR}/${sub_id}.json"
    echo "    Exported sub-workflow: ${OUT_DIR}/${sub_id}.json"
  done
fi
