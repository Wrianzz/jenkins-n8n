#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: export-to-git.sh <WORKFLOW_ID> [SUB_WORKFLOW_IDS_CSV]}"
SUB_WORKFLOW_IDS_CSV="${2:-}"

DEV_SSH_HOST="${DEV_SSH_HOST:?DEV_SSH_HOST is required}"
DEV_SSH_USER="${DEV_SSH_USER:-}"
DEV_SSH_PORT="${DEV_SSH_PORT:-22}"
DEV_DEPLOY_TARGET="${DEV_DEPLOY_TARGET:-docker}"
DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev}"
DEV_K8S_NAMESPACE="${DEV_K8S_NAMESPACE:-default}"
DEV_K8S_POD_SELECTOR="${DEV_K8S_POD_SELECTOR:-app=n8n}"
DEV_K8S_CONTAINER="${DEV_K8S_CONTAINER:-}"
DEV_PG_HOST="${DEV_PG_HOST:?DEV_PG_HOST is required}"
DEV_PG_PORT="${DEV_PG_PORT:-5432}"
DEV_PG_DATABASE="${DEV_PG_DATABASE:-n8n}"
DEV_PG_USER="${DEV_PG_USER:-n8n}"
DEV_PG_PASSWORD="${DEV_PG_PASSWORD:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
DEV_N8N_API_BASE_URL="${DEV_N8N_API_BASE_URL:?DEV_N8N_API_BASE_URL is required}"
DEV_N8N_API_KEY="${DEV_N8N_API_KEY:?DEV_N8N_API_KEY is required}"

# Exit code reserved for workflow/user configuration errors.
HUMAN_ERROR_EXIT_CODE=42

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/workflows"
TMP_DIR="/tmp/n8n-export-${WORKFLOW_ID}"
LOCAL_FILE="${TMP_DIR}/${WORKFLOW_ID}.json"
REMOTE_TMP_DIR="/tmp/n8n-git-${WORKFLOW_ID}"
REMOTE_HOST="${DEV_SSH_USER:+${DEV_SSH_USER}@}${DEV_SSH_HOST}"
SSH_OPTS=( -p "$DEV_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
if [[ -n "$SSH_KEY_FILE" ]]; then
  SSH_OPTS+=( -i "$SSH_KEY_FILE" )
fi

remote_quote() {
  printf "%q" "$1"
}

remote_psql() {
  local sql="$1"

  PGPASSWORD="$DEV_PG_PASSWORD" psql \
    -h "$DEV_PG_HOST" \
    -p "$DEV_PG_PORT" \
    -U "$DEV_PG_USER" \
    -d "$DEV_PG_DATABASE" \
    -tA -c "$sql"
}

dev_kubectl_exec_prefix() {
  local pod_cmd container_arg
  pod_cmd="kubectl -n $(remote_quote "$DEV_K8S_NAMESPACE") get pod -l $(remote_quote "$DEV_K8S_POD_SELECTOR") -o jsonpath='{.items[0].metadata.name}'"
  container_arg=""
  if [[ -n "$DEV_K8S_CONTAINER" ]]; then
    container_arg="-c $(remote_quote "$DEV_K8S_CONTAINER")"
  fi

  printf "pod=\\$(%s); test -n \\\"\\$pod\\\"; kubectl -n %s exec \\\"\\$pod\\\" %s --" \
    "$pod_cmd" "$(remote_quote "$DEV_K8S_NAMESPACE")" "$container_arg"
}

n8n_exec() {
  local inner="$1"

  case "$DEV_DEPLOY_TARGET" in
    docker)
      ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
        "docker exec '$DEV_CONTAINER' sh -lc $(remote_quote "$inner")"
      ;;
    kubernetes|kubectl)
      ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
        "$(dev_kubectl_exec_prefix) sh -lc $(remote_quote "$inner")"
      ;;
    *)
      echo "[ERR] Unsupported DEV_DEPLOY_TARGET: $DEV_DEPLOY_TARGET (use docker or kubernetes)"
      exit 1
      ;;
  esac
}

# Resolve workflow IDs through the DEV n8n API before touching SSH/docker/kubectl.
# 404 means the supplied workflowId does not exist (human/config error).
# Authentication/server/network failures remain normal exit 1 (system failure).
validate_workflow_id_exists() {
  local workflow_id="$1"
  local response_file http_code
  response_file="$(mktemp)"
  trap 'rm -f "$response_file"' RETURN

  http_code="$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -H "X-N8N-API-KEY: ${DEV_N8N_API_KEY}" \
    "${DEV_N8N_API_BASE_URL%/}/workflows/${workflow_id}")"

  case "$http_code" in
    200)
      echo "[INFO] DEV workflow ID validated: ${workflow_id}"
      ;;
    400|404)
      echo "[HUMAN_ERROR] Workflow ID not found on DEV n8n: ${workflow_id}"
      exit "$HUMAN_ERROR_EXIT_CODE"
      ;;
    401|403)
      echo "[ERR] DEV n8n API authentication/authorization failed while validating workflow ID ${workflow_id} (HTTP ${http_code})"
      cat "$response_file" >&2 || true
      exit 1
      ;;
    *)
      echo "[ERR] DEV n8n API failed while validating workflow ID ${workflow_id} (HTTP ${http_code})"
      cat "$response_file" >&2 || true
      exit 1
      ;;
  esac
}

mkdir -p "$OUT_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

validate_workflow_id_exists "$WORKFLOW_ID"

echo "[1] Export main workflow on DEV server"
n8n_exec "rm -rf '${REMOTE_TMP_DIR}' && mkdir -p '${REMOTE_TMP_DIR}' && n8n export:workflow --id \"$WORKFLOW_ID\" --output '${REMOTE_TMP_DIR}/${WORKFLOW_ID}.json' --pretty"

echo "[2] Copy exported file from DEV server"
n8n_exec "cat '${REMOTE_TMP_DIR}/${WORKFLOW_ID}.json'" > "$LOCAL_FILE"
echo "[2.5] Fetching Folder & Owner Metadata directly from DEV PostgreSQL"

TEAM_NAME=$(remote_psql "
  SELECT trim(concat_ws(' ', u.\"firstName\", u.\"lastName\"))
  FROM shared_workflow sw
  JOIN project p ON sw.\"projectId\" = p.id
  JOIN \"user\" u ON p.\"creatorId\" = u.id
  WHERE sw.\"workflowId\" = '${WORKFLOW_ID}' AND sw.role = 'workflow:owner'
  LIMIT 1;
" | tr -d '\r' | xargs)

TEAM_NAME=${TEAM_NAME:-"Unassigned Team"}

FOLDER_PATH=$(remote_psql "
WITH RECURSIVE folder_hierarchy AS (
    SELECT
        w.id AS workflow_id,
        f.id AS folder_id,
        f.name AS folder_name,
        f.\"parentFolderId\" AS parent_id,
        1 AS depth,
        ARRAY[f.name::text] AS path_array
    FROM workflow_entity w
    JOIN folder f ON w.\"parentFolderId\" = f.id
    WHERE w.id = '${WORKFLOW_ID}'
    UNION ALL
    SELECT
        fh.workflow_id,
        f.id AS folder_id,
        f.name AS folder_name,
        f.\"parentFolderId\" AS parent_id,
        fh.depth + 1,
        f.name::text || fh.path_array
    FROM folder_hierarchy fh
    JOIN folder f ON fh.parent_id = f.id
)
SELECT array_to_string(path_array, '/') FROM folder_hierarchy ORDER BY depth DESC LIMIT 1;
" | tr -d '\r' | xargs)

FINAL_PATH=""
if [ -n "$FOLDER_PATH" ]; then
  FINAL_PATH="${TEAM_NAME}/${FOLDER_PATH}"
else
  FINAL_PATH="${TEAM_NAME}"
fi

mkdir -p "${OUT_DIR}/metadata"
echo "$FINAL_PATH" > "${OUT_DIR}/metadata/${WORKFLOW_ID}.meta"

echo "[INFO] Workflow Owner detected: ${TEAM_NAME}"
if [ -z "$FOLDER_PATH" ]; then
  echo "[INFO] Folder mapped to Root of Team: ${FINAL_PATH}"
else
  echo "[INFO] Folder mapped to Sub-folder: ${FINAL_PATH}"
fi

echo "[3] Normalize JSON for cleaner diffs"
jq -S '.' "$LOCAL_FILE" > "${OUT_DIR}/${WORKFLOW_ID}.json"

echo "[4] Done: ${OUT_DIR}/${WORKFLOW_ID}.json"

if [[ -n "$SUB_WORKFLOW_IDS_CSV" ]]; then
  echo "[5] Export selected sub-workflow(s): $SUB_WORKFLOW_IDS_CSV"
  SUB_WORKFLOW_IDS_NORMALIZED="$(echo "$SUB_WORKFLOW_IDS_CSV" | tr ',\n\r\t' '    ')"
  for sub_id_raw in $SUB_WORKFLOW_IDS_NORMALIZED; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue

    validate_workflow_id_exists "$sub_id"
    n8n_exec "n8n export:workflow --id \"$sub_id\" --output '${REMOTE_TMP_DIR}/${sub_id}.json' --pretty"
    n8n_exec "cat '${REMOTE_TMP_DIR}/${sub_id}.json'" > "${TMP_DIR}/${sub_id}.json"
    jq -S '.' "${TMP_DIR}/${sub_id}.json" > "${OUT_DIR}/${sub_id}.json"
    echo "    Exported sub-workflow: ${OUT_DIR}/${sub_id}.json"
  done
fi

echo "[6] Cleaning up remote temporary files..."
n8n_exec "rm -rf '${REMOTE_TMP_DIR}'"