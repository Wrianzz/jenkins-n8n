#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/deploy-from-git.sh <WORKFLOW_ID>
#   scripts/deploy-from-git.sh --file workflows/<something>.json

PROD_SSH_HOST="${PROD_SSH_HOST:?PROD_SSH_HOST is required}"
PROD_SSH_USER="${PROD_SSH_USER:-}"
PROD_SSH_PORT="${PROD_SSH_PORT:-22}"
PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_PG_CONTAINER="${PROD_PG_CONTAINER:-n8n-prod-postgres-prod-1}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_DIR="${REPO_ROOT}/workflows"
EXTRACT_FILTER="${REPO_ROOT}/scripts/extract-cred-ids.jq"
PROMOTE_SCRIPT="${REPO_ROOT}/scripts/promote-creds.sh"

PROD_REMOTE="${PROD_SSH_USER:+${PROD_SSH_USER}@}${PROD_SSH_HOST}"
PROD_SSH_OPTS=( -p "$PROD_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
PROD_SCP_OPTS=( -P "$PROD_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
if [[ -n "$SSH_KEY_FILE" ]]; then
  PROD_SSH_OPTS+=( -i "$SSH_KEY_FILE" )
  PROD_SCP_OPTS+=( -i "$SSH_KEY_FILE" )
fi

PROD_PROJECT_ID="$(ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker exec '$PROD_PG_CONTAINER' psql -U n8n -d n8n -tA -c \"select id from project order by \\\"createdAt\\\" asc limit 1;\"" | tr -d '\r' | xargs)"
[[ -n "$PROD_PROJECT_ID" ]] || { echo "[ERR] PROD_PROJECT_ID not found"; exit 1; }

WF_FILE=""
if [[ "${1:-}" == "--file" ]]; then
  WF_FILE="${2:?usage: deploy-from-git.sh --file <path-to-json>}"
  [[ "$WF_FILE" = /* ]] || WF_FILE="${REPO_ROOT}/${WF_FILE}"
else
  WORKFLOW_ID="${1:?usage: deploy-from-git.sh <WORKFLOW_ID>}"
  WF_FILE="${WF_DIR}/${WORKFLOW_ID}.json"
fi

[[ -f "$WF_FILE" ]] || { echo "[ERR] Workflow file not found: $WF_FILE"; exit 1; }
[[ -f "$EXTRACT_FILTER" ]] || { echo "[ERR] jq filter not found: $EXTRACT_FILTER"; exit 1; }
[[ -x "$PROMOTE_SCRIPT" ]] || { echo "[ERR] promote script not executable: $PROMOTE_SCRIPT"; exit 1; }

WORKFLOW_ID="$(jq -r '.id // empty' "$WF_FILE")"
[[ -n "$WORKFLOW_ID" ]] || { echo "[ERR] Workflow id not found in file: $WF_FILE"; exit 1; }

SOURCE_ACTIVE="$(jq -r '.active // false' "$WF_FILE")"
PROD_ACTIVE_RAW="$(ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker exec '$PROD_PG_CONTAINER' psql -U n8n -d n8n -tA -c \"select active from workflow_entity where id='${WORKFLOW_ID}' limit 1;\"" | tr -d '\r' | xargs || true)"

WF_FILE_TO_IMPORT="$WF_FILE"
TMP_IMPORT_FILE=""
if [[ "$PROD_ACTIVE_RAW" == "t" || "$PROD_ACTIVE_RAW" == "true" ]]; then
  if [[ "$SOURCE_ACTIVE" != "true" ]]; then
    TMP_IMPORT_FILE="$(mktemp "${TMPDIR:-/tmp}/wf-import-${WORKFLOW_ID}.XXXXXX.json")"
    jq '.active = true' "$WF_FILE" > "$TMP_IMPORT_FILE"
    WF_FILE_TO_IMPORT="$TMP_IMPORT_FILE"
    echo "[INFO] Workflow aktif di PROD, pakai active=true saat import agar tetap aktif"
  fi
fi

cleanup() {
  [[ -n "$TMP_IMPORT_FILE" && -f "$TMP_IMPORT_FILE" ]] && rm -f "$TMP_IMPORT_FILE"
}
trap cleanup EXIT

base="$(basename "$WF_FILE")"
remote_host_file="/tmp/${base}"
remote_container_file="/tmp/${base}"

echo "[0] Scan credential IDs from workflow"
mapfile -t CRED_IDS < <(jq -r -f "$EXTRACT_FILTER" "$WF_FILE" | awk 'NF' | sort -u)

if [[ "${#CRED_IDS[@]}" -gt 0 ]]; then
  CRED_IDS_RAW="${CRED_IDS[*]}"
  echo "    Found ${#CRED_IDS[@]} credential ID(s): ${CRED_IDS_RAW}"
  echo "[1] Promote credentials to PROD"
  "$PROMOTE_SCRIPT" "$CRED_IDS_RAW"
else
  echo "    No credential IDs found in workflow; skip promote creds"
fi

echo "[2] Transfer and import workflow to PROD"
scp "${PROD_SCP_OPTS[@]}" "$WF_FILE_TO_IMPORT" "$PROD_REMOTE:$remote_host_file"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker cp '$remote_host_file' '$PROD_CONTAINER:$remote_container_file' && docker exec '$PROD_CONTAINER' n8n import:workflow --input '$remote_container_file' --projectId '$PROD_PROJECT_ID'"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "rm -f '$remote_host_file'; docker exec '$PROD_CONTAINER' sh -lc 'rm -f \"$remote_container_file\" || true'"

echo "[3] Done"
