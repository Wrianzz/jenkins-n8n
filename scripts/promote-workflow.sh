#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: promote-workflow.sh <WORKFLOW_ID>}"

DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev}"
PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod}"

ROOT="/promotion"
RUN_ID="$(date +%Y%m%d-%H%M%S)-wf${WORKFLOW_ID}"
DIR="${ROOT}/run-${RUN_ID}"
WF="${DIR}/workflow.json"
CREDS_DIR="${DIR}/creds"

echo "[0] Prepare dir: ${DIR}"
docker exec -u root "$DEV_CONTAINER" sh -lc "mkdir -p '${CREDS_DIR}' && chown -R 1000:1000 '${DIR}'"

echo "[1] Export workflow from DEV"
# export:workflow flags resmi di docs
docker exec "$DEV_CONTAINER" n8n export:workflow --id "$WORKFLOW_ID" --output "$WF" --pretty

echo "[2] Extract credential IDs from workflow"
TMP_IDS="/tmp/cred_ids_${RUN_ID}.txt"
cat <(docker exec "$DEV_CONTAINER" sh -lc "cat '$WF'") \
  | jq -r -f scripts/extract-cred-ids.jq \
  | sort -u > "$TMP_IDS" || true

echo "[3] Export credentials (encrypted/default) from DEV"
# export:credentials flags resmi di docs
while read -r CID; do
  [ -z "$CID" ] && continue
  echo "  - exporting credential id=$CID"
  docker exec "$DEV_CONTAINER" n8n export:credentials --id "$CID" --output "${CREDS_DIR}/cred_${CID}.json"
done < "$TMP_IDS"

echo "[4] Import credentials into PROD"
# import:credentials --separate resmi di docs
docker exec "$PROD_CONTAINER" n8n import:credentials --separate --input "$CREDS_DIR"

echo "[5] Import workflow into PROD"
docker exec "$PROD_CONTAINER" n8n import:workflow --input "$WF"

echo "[6] Done"
