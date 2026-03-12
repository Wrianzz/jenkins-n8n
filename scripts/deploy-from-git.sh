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

echo "[0] Validate workflow credentials naming"
if ! INVALID_CREDENTIAL_NODES="$(jq -r '
  def workflow_objects:
    if type == "array" then .[] else . end;

  workflow_objects
  | .nodes[]?
  | select((.credentials? | type) == "object") as $node
  | ($node.credentials | to_entries[]?) as $cred
  | ($cred.value.name // "") as $credName
  | select(($credName | test("-production$"; "i")) | not)
  | "- node=\($node.name // "<unnamed>") credentialType=\($cred.key) credentialName=\($credName)"
' "$WF_FILE")"; then
  echo "[ERR] Failed to parse workflow JSON structure while validating credentials: $WF_FILE"
  exit 1
fi

if [[ -n "$INVALID_CREDENTIAL_NODES" ]]; then
  echo "[ERR] Found non-production credential name(s)."
  echo "[ERR] Every credential in workflow must use the format: <Nama-kredensial>-Production (case-insensitive)."
  echo "$INVALID_CREDENTIAL_NODES"
  exit 1
fi

echo "    OK: all node credentials already use suffix -Production (case-insensitive)."

base="$(basename "$WF_FILE")"
remote_host_file="/tmp/${base}"
remote_container_file="/tmp/${base}"

echo "[1] Scan credential IDs from workflow"
mapfile -t CRED_IDS < <(jq -r -f "$EXTRACT_FILTER" "$WF_FILE" | awk 'NF' | sort -u)

if [[ "${#CRED_IDS[@]}" -gt 0 ]]; then
  CRED_IDS_RAW="${CRED_IDS[*]}"
  echo "    Found ${#CRED_IDS[@]} credential ID(s): ${CRED_IDS_RAW}"
  echo "[2] Promote credentials to PROD"
  "$PROMOTE_SCRIPT" "$CRED_IDS_RAW"
else
  echo "    No credential IDs found in workflow; skip promote creds"
fi

echo "[3] Transfer and import workflow to PROD"
scp "${PROD_SCP_OPTS[@]}" "$WF_FILE" "$PROD_REMOTE:$remote_host_file"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker cp '$remote_host_file' '$PROD_CONTAINER:$remote_container_file' && docker exec '$PROD_CONTAINER' n8n import:workflow --input '$remote_container_file' --projectId '$PROD_PROJECT_ID'"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker exec '$PROD_CONTAINER' n8n publish:workflow --id='$WORKFLOW_ID'"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "rm -f '$remote_host_file'; docker exec '$PROD_CONTAINER' sh -lc 'rm -f \"$remote_container_file\" || true'"

echo "[4] Done"
