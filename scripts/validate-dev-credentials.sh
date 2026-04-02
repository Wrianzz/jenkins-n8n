#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: validate-dev-credentials.sh <WORKFLOW_ID>}"

DEV_SSH_HOST="${DEV_SSH_HOST:?DEV_SSH_HOST is required}"
DEV_SSH_USER="${DEV_SSH_USER:-}"
DEV_SSH_PORT="${DEV_SSH_PORT:-22}"
DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev-n8n-dev-1}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

TMP_DIR="${TMPDIR:-/tmp}/n8n-validate-${WORKFLOW_ID}-$$"
WF_FILE="${TMP_DIR}/${WORKFLOW_ID}.json"
REMOTE_HOST="${DEV_SSH_USER:+${DEV_SSH_USER}@}${DEV_SSH_HOST}"
SSH_OPTS=( -p "$DEV_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
if [[ -n "$SSH_KEY_FILE" ]]; then
  SSH_OPTS+=( -i "$SSH_KEY_FILE" )
fi

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

echo "[0] Export workflow from DEV"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' sh -lc 'rm -rf /tmp/n8n-validate && mkdir -p /tmp/n8n-validate && n8n export:workflow --id \"$WORKFLOW_ID\" --output /tmp/n8n-validate/${WORKFLOW_ID}.json --pretty'"

ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' cat '/tmp/n8n-validate/${WORKFLOW_ID}.json'" > "$WF_FILE"

echo "[1] Validate workflow credentials naming"
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

echo "[OK] All node credentials already use suffix -Production (case-insensitive)."
