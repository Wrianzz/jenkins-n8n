#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/deploy-from-git.sh <WORKFLOW_ID>
#   scripts/deploy-from-git.sh --file workflows/<something>.json

PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_PG_CONTAINER="${PROD_PG_CONTAINER:-n8n-prod-postgres-prod-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_DIR="${REPO_ROOT}/workflows"
EXTRACT_FILTER="${REPO_ROOT}/scripts/extract-cred-ids.jq"
PROMOTE_SCRIPT="${REPO_ROOT}/scripts/promote-creds.sh"

# auto projectId (prod kamu 1 project)
PROD_PROJECT_ID="$(docker exec "$PROD_PG_CONTAINER" psql -U n8n -d n8n -tA -c \
  "select id from project order by \"createdAt\" asc limit 1;" | tr -d '\r' | xargs)"
[[ -n "$PROD_PROJECT_ID" ]] || { echo "[ERR] PROD_PROJECT_ID not found"; exit 1; }

# Resolve input
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

base="$(basename "$WF_FILE")"
remote="/tmp/${base}"

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

echo "[2] Import one workflow to PROD"
echo "    File: $WF_FILE"
echo "    PROD_PROJECT_ID: $PROD_PROJECT_ID"

docker cp "$WF_FILE" "${PROD_CONTAINER}:${remote}"
docker exec "$PROD_CONTAINER" n8n import:workflow --input "$remote" --projectId "$PROD_PROJECT_ID"

# optional cleanup
docker exec "$PROD_CONTAINER" sh -lc "rm -f '$remote' || true"

echo "[3] Done"
