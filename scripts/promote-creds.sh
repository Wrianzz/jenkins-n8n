#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/promote-creds.sh "id1 id2 id3"
#   scripts/promote-creds.sh "id1,id2,id3"
CRED_IDS_RAW="${1:?usage: promote-creds.sh \"<CRED_IDs space/comma-separated>\"}"

DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev-n8n-dev-1}"
PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_PG_CONTAINER="${PROD_PG_CONTAINER:-n8n-prod-postgres-prod-1}"

ROOT="/promotion"
RUN_ID="$(date +%Y%m%d-%H%M%S)-creds"
DIR="${ROOT}/run-${RUN_ID}"
CREDS_DIR="${DIR}/creds"

# normalize input: comma -> space, collapse spaces
CRED_IDS="$(echo "$CRED_IDS_RAW" | tr ',' ' ' | xargs)"

get_prod_project_id() {
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
  docker exec "$PROD_PG_CONTAINER" psql -U n8n -d n8n -tA -c \
    "insert into shared_credentials(\"credentialsId\",\"projectId\",\"role\")
     values ('$cid','$pid','credential:owner')
     on conflict do nothing;" >/dev/null
}

echo "[0] Prepare dir: ${DIR}"
# create on DEV volume mount, then chown so n8n user can write
docker exec -u root "$DEV_CONTAINER" sh -lc "mkdir -p '${CREDS_DIR}' && chown -R 1000:1000 '${DIR}'"

echo "[1] Determine PROD projectId (auto, prod=1 project)"
PROD_PROJECT_ID="$(get_prod_project_id)"
echo "    PROD_PROJECT_ID=${PROD_PROJECT_ID}"

echo "[2] Export credentials from DEV"
count=0
for CID in $CRED_IDS; do
  [[ -z "${CID:-}" ]] && continue
  echo "  - exporting credential id=$CID"
  docker exec "$DEV_CONTAINER" n8n export:credentials --id "$CID" --output "${CREDS_DIR}/cred_${CID}.json"
  count=$((count+1))
done

if [[ "$count" -eq 0 ]]; then
  echo "[ERR] No credential IDs provided after normalization."
  exit 1
fi

echo "[3] Import credentials into PROD (project attached)"
docker exec "$PROD_CONTAINER" n8n import:credentials --separate --input "$CREDS_DIR" --projectId "$PROD_PROJECT_ID" || true

echo "[4] Ensure shared_credentials mapping exists (DB upsert)"
for CID in $CRED_IDS; do
  [[ -z "${CID:-}" ]] && continue
  share_credential_to_project "$CID" "$PROD_PROJECT_ID"
done

echo "[5] Done"
