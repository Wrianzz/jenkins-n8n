#!/usr/bin/env bash
set -euo pipefail

CRED_IDS_RAW="${1:?usage: promote-creds.sh \"<CRED_IDs space/comma-separated>\"}"

DEV_SSH_HOST="${DEV_SSH_HOST:?DEV_SSH_HOST is required}"
DEV_SSH_USER="${DEV_SSH_USER:-}"
DEV_SSH_PORT="${DEV_SSH_PORT:-22}"
DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev-n8n-dev-1}"
DEV_PG_CONTAINER="${DEV_PG_CONTAINER:-n8n-postgres-dev-1}"
DEV_PROJECT_ID="${DEV_PROJECT_ID:-}"

PROD_SSH_HOST="${PROD_SSH_HOST:?PROD_SSH_HOST is required}"
PROD_SSH_USER="${PROD_SSH_USER:-}"
PROD_SSH_PORT="${PROD_SSH_PORT:-22}"
PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_PG_CONTAINER="${PROD_PG_CONTAINER:-n8n-prod-postgres-prod-1}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

RUN_ID="$(date +%Y%m%d-%H%M%S)-creds"
TMP_DIR="/tmp/n8n-promote-${RUN_ID}"
CREDS_DIR="${TMP_DIR}/creds"

DEV_REMOTE="${DEV_SSH_USER:+${DEV_SSH_USER}@}${DEV_SSH_HOST}"
PROD_REMOTE="${PROD_SSH_USER:+${PROD_SSH_USER}@}${PROD_SSH_HOST}"
DEV_SSH_OPTS=( -p "$DEV_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
PROD_SSH_OPTS=( -p "$PROD_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
PROD_SCP_OPTS=( -P "$PROD_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
if [[ -n "$SSH_KEY_FILE" ]]; then
  DEV_SSH_OPTS+=( -i "$SSH_KEY_FILE" )
  PROD_SSH_OPTS+=( -i "$SSH_KEY_FILE" )
  PROD_SCP_OPTS+=( -i "$SSH_KEY_FILE" )
fi

CRED_IDS="$(echo "$CRED_IDS_RAW" | tr ',' ' ' | xargs)"

get_project_id() {
  local remote="$1"
  local -n ssh_opts_ref=$2
  local pg_container="$3"
  local pid
  pid="$(ssh "${ssh_opts_ref[@]}" "$remote" \
    "docker exec '$pg_container' psql -U n8n -d n8n -tA -c \"select id from project order by \\\"createdAt\\\" asc limit 1;\"" \
    | tr -d '\r' | xargs || true)"
  [[ -n "$pid" ]] || { echo "[ERR] Cannot determine projectId on $remote"; exit 1; }
  echo "$pid"
}

share_credential_to_project() {
  local cid="$1"
  local pid="$2"
  ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
    "docker exec '$PROD_PG_CONTAINER' psql -U n8n -d n8n -tA -c \"insert into shared_credentials(\\\"credentialsId\\\",\\\"projectId\\\",\\\"role\\\") values ('$cid','$pid','credential:owner') on conflict do nothing;\"" >/dev/null
}

export_credential_from_dev() {
  local cid="$1"
  local dev_project_id="$2"

  if ssh "${DEV_SSH_OPTS[@]}" "$DEV_REMOTE" \
    "docker exec '$DEV_CONTAINER' n8n export:credentials --id '$cid' --projectId '$dev_project_id' --decrypted --output /tmp/cred_${cid}.json"; then
    return 0
  fi

  echo "[WARN] Export with --projectId failed for credential $cid, retrying without --projectId"
  ssh "${DEV_SSH_OPTS[@]}" "$DEV_REMOTE" \
    "docker exec '$DEV_CONTAINER' n8n export:credentials --id '$cid' --decrypted --output /tmp/cred_${cid}.json"
}

mkdir -p "$CREDS_DIR"
PROD_PROJECT_ID="$(get_project_id "$PROD_REMOTE" PROD_SSH_OPTS "$PROD_PG_CONTAINER")"
if [[ -z "$DEV_PROJECT_ID" ]]; then
  DEV_PROJECT_ID="$(get_project_id "$DEV_REMOTE" DEV_SSH_OPTS "$DEV_PG_CONTAINER")"
fi

count=0
for CID in $CRED_IDS; do
  [[ -z "${CID:-}" ]] && continue
  export_credential_from_dev "$CID" "$DEV_PROJECT_ID"
  ssh "${DEV_SSH_OPTS[@]}" "$DEV_REMOTE" \
    "docker exec '$DEV_CONTAINER' cat /tmp/cred_${CID}.json" > "${CREDS_DIR}/cred_${CID}.json"
  count=$((count+1))
done
[[ "$count" -gt 0 ]] || { echo "[ERR] No credential IDs provided after normalization."; exit 1; }

ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" "mkdir -p '/tmp/n8n-promote-creds-${RUN_ID}'"
scp "${PROD_SCP_OPTS[@]}" "${CREDS_DIR}"/*.json "$PROD_REMOTE:/tmp/n8n-promote-creds-${RUN_ID}/"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker cp /tmp/n8n-promote-creds-${RUN_ID} '$PROD_CONTAINER:/tmp/n8n-promote-creds-${RUN_ID}' && docker exec '$PROD_CONTAINER' n8n import:credentials --separate --input /tmp/n8n-promote-creds-${RUN_ID} --projectId '$PROD_PROJECT_ID'"

for CID in $CRED_IDS; do
  [[ -z "${CID:-}" ]] && continue
  share_credential_to_project "$CID" "$PROD_PROJECT_ID"
done

ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "rm -rf /tmp/n8n-promote-creds-${RUN_ID}; docker exec '$PROD_CONTAINER' sh -lc 'rm -rf /tmp/n8n-promote-creds-${RUN_ID} /tmp/cred_*.json || true'"
ssh "${DEV_SSH_OPTS[@]}" "$DEV_REMOTE" \
  "docker exec '$DEV_CONTAINER' sh -lc 'rm -f /tmp/cred_*.json || true'"
rm -rf "$TMP_DIR"

echo "[OK] Promote credentials selesai"
