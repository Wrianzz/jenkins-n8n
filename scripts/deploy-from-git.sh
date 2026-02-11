#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/deploy-one-from-git.sh <WORKFLOW_ID>
#   scripts/deploy-one-from-git.sh --file workflows/<something>.json

PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_PG_CONTAINER="${PROD_PG_CONTAINER:-n8n-prod-postgres-prod-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_DIR="${REPO_ROOT}/workflows"

# auto projectId (prod kamu 1 project)
PROD_PROJECT_ID="$(docker exec "$PROD_PG_CONTAINER" psql -U n8n -d n8n -tA -c \
  "select id from project order by \"createdAt\" asc limit 1;" | tr -d '\r' | xargs)"
[[ -n "$PROD_PROJECT_ID" ]] || { echo "[ERR] PROD_PROJECT_ID not found"; exit 1; }

# Resolve input
WF_FILE=""
if [[ "${1:-}" == "--file" ]]; then
  WF_FILE="${2:?usage: deploy-one-from-git.sh --file <path-to-json>}"
  [[ "$WF_FILE" = /* ]] || WF_FILE="${REPO_ROOT}/${WF_FILE}"
else
  WORKFLOW_ID="${1:?usage: deploy-one-from-git.sh <WORKFLOW_ID>}"
  WF_FILE="${WF_DIR}/${WORKFLOW_ID}.json"
fi

[[ -f "$WF_FILE" ]] || { echo "[ERR] Workflow file not found: $WF_FILE"; exit 1; }

base="$(basename "$WF_FILE")"
remote="/tmp/${base}"

echo "[0] Import one workflow to PROD"
echo "    File: $WF_FILE"
echo "    PROD_PROJECT_ID: $PROD_PROJECT_ID"

docker cp "$WF_FILE" "${PROD_CONTAINER}:${remote}"
docker exec "$PROD_CONTAINER" n8n import:workflow --input "$remote" --projectId "$PROD_PROJECT_ID"

# optional cleanup
docker exec "$PROD_CONTAINER" sh -lc "rm -f '$remote' || true"

echo "[1] Done"
