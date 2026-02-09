#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: promote-workflow.sh <WORKFLOW_ID>}"

DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev-n8n-dev-1}"
PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_PG_CONTAINER="${PROD_PG_CONTAINER:-n8n-prod-postgres-prod-1}"

ROOT="/promotion"
RUN_ID="$(date +%Y%m%d-%H%M%S)-wf${WORKFLOW_ID}"
DIR="${ROOT}/run-${RUN_ID}"
WF="${DIR}/workflow.json"
CREDS_DIR="${DIR}/creds"

get_prod_project_id() {
  # Prod kamu cuma 1 project → ambil yang paling awal
  local pid
  pid="$(docker exec "$PROD_PG_CONTAINER" psql -U n8n -d n8n -tA -c \
    "select id from project order by \"createdAt\" asc limit 1;" \
    | tr -d '\r' | xargs || true)"
  [[ -n "$pid" ]] || { echo "[ERR] Cannot determine PROD projectId"; exit 1; }
  echo "$pid"
}

share_credential_to_project() {
  local cid="$1"
  local pid="$2"

  # Upsert mapping credential → project (biar credential bisa diakses dari workflow/editor)
  docker exec "$PROD_PG_CONTAINER" psql -U n8n -d n8n -tA -c \
    "insert into shared_credentials(\"credentialsId\",\"projectId\",\"role\")
     values ('$cid','$pid','credential:owner')
     on conflict do nothing;" >/dev/null
}

echo "[0] Prepare dir: ${DIR}"
docker exec -u root "$DEV_CONTAINER" sh -lc "mkdir -p '${CREDS_DIR}' && chown -R 1000:1000 '${DIR}'"

echo "[1] Export workflow from DEV"
docker exec "$DEV_CONTAINER" n8n export:workflow --id "$WORKFLOW_ID" --output "$WF" --pretty

echo "[2] Extract credential IDs from workflow"
TMP_IDS="/tmp/cred_ids_${RUN_ID}.txt"
cat <(docker exec "$DEV_CONTAINER" sh -lc "cat '$WF'") \
  | jq -r -f scripts/extract-cred-ids.jq \
  | sort -u > "$TMP_IDS" || true

echo "[3] Export credentials (encrypted/default) from DEV"
while read -r CID; do
  [[ -z "${CID:-}" ]] && continue
  echo "  - exporting credential id=$CID"
  docker exec "$DEV_CONTAINER" n8n export:credentials --id "$CID" --output "${CREDS_DIR}/cred_${CID}.json"
done < "$TMP_IDS"

echo "[3.5] Determine PROD projectId (auto)"
PROD_PROJECT_ID="$(get_prod_project_id)"
echo "[3.6] Using PROD_PROJECT_ID=${PROD_PROJECT_ID}"

echo "[4] Import credentials into PROD"
docker exec "$PROD_CONTAINER" n8n import:credentials --separate --input "$CREDS_DIR" --projectId "$PROD_PROJECT_ID" || true

echo "[4.1] Ensure shared_credentials mapping exists (DB upsert)"
# Untuk setiap credentialId yang dipakai workflow, pastikan ada row di shared_credentials
while read -r CID; do
  [[ -z "${CID:-}" ]] && continue
  share_credential_to_project "$CID" "$PROD_PROJECT_ID"
done < "$TMP_IDS"

echo "[5] Import workflow into PROD"
docker exec "$PROD_CONTAINER" n8n import:workflow --input "$WF" --projectId "$PROD_PROJECT_ID"

echo "[6] Done"
