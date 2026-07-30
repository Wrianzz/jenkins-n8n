#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: export-to-git.sh <WORKFLOW_ID> [SUB_WORKFLOW_IDS_CSV]}"
SUB_WORKFLOW_IDS_CSV="${2:-}"

DEV_SSH_HOST="${DEV_SSH_HOST:?DEV_SSH_HOST is required}"
DEV_SSH_USER="${DEV_SSH_USER:-}"
DEV_SSH_PORT="${DEV_SSH_PORT:-22}"
DEV_PG_CONTAINER="${DEV_PG_CONTAINER:-n8n-dev-postgres}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/workflows"
TMP_DIR="/tmp/n8n-export-${WORKFLOW_ID}"
LOCAL_FILE="${TMP_DIR}/${WORKFLOW_ID}.json"
REMOTE_HOST="${DEV_SSH_USER:+${DEV_SSH_USER}@}${DEV_SSH_HOST}"
SSH_OPTS=( -p "$DEV_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
if [[ -n "$SSH_KEY_FILE" ]]; then
  SSH_OPTS+=( -i "$SSH_KEY_FILE" )
fi

mkdir -p "$OUT_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

echo "[1] Export main workflow on DEV server"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' sh -lc 'rm -rf /tmp/n8n-git && mkdir -p /tmp/n8n-git && n8n export:workflow --id \"$WORKFLOW_ID\" --output /tmp/n8n-git/${WORKFLOW_ID}.json --pretty'"

echo "[2] Copy exported file from DEV server"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' cat '/tmp/n8n-git/${WORKFLOW_ID}.json'" > "$LOCAL_FILE"

echo "[2.5] Fetching Folder & Owner Metadata directly from DEV PostgreSQL"

# 1. AMBIL NAMA TIM/OWNER DARI DATABASE DEV
TEAM_NAME=$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "docker exec -i '$DEV_PG_CONTAINER' psql -U n8n -d n8n -tA -c \"
  SELECT trim(u.\\\"firstName\\\" || ' ' || COALESCE(u.\\\"lastName\\\", ''))
  FROM shared_workflow sw
  JOIN project p ON sw.\\\"projectId\\\" = p.id
  JOIN \\\"user\\\" u ON p.\\\"creatorId\\\" = u.id
  WHERE sw.\\\"workflowId\\\" = '${WORKFLOW_ID}' AND sw.role = 'workflow:owner'
  LIMIT 1;
\"" | tr -d '\r' | xargs)

# Fallback jika workflow tidak memiliki owner jelas
TEAM_NAME=${TEAM_NAME:-"Unassigned Team"}

# 2. AMBIL HIRARKI FOLDER ASLI DARI DATABASE DEV
FOLDER_PATH=$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "docker exec -i '$DEV_PG_CONTAINER' psql -U n8n -d n8n -tA" <<EOF | tr -d '\r' | xargs
WITH RECURSIVE folder_hierarchy AS (
    SELECT 
        w.id AS workflow_id,
        f.id AS folder_id,
        f.name AS folder_name,
        f."parentFolderId" AS parent_id,
        1 AS depth,
        ARRAY[f.name::text] AS path_array
    FROM workflow_entity w
    JOIN folder f ON w."parentFolderId" = f.id
    WHERE w.id = '${WORKFLOW_ID}'
    UNION ALL
    SELECT 
        fh.workflow_id,
        f.id AS folder_id,
        f.name AS folder_name,
        f."parentFolderId" AS parent_id,
        fh.depth + 1,
        f.name::text || fh.path_array
    FROM folder_hierarchy fh
    JOIN folder f ON fh.parent_id = f.id
)
SELECT array_to_string(path_array, '/') FROM folder_hierarchy ORDER BY depth DESC LIMIT 1;
EOF
)

# 3. GABUNGKAN NAMA TIM SEBAGAI ROOT FOLDER
FINAL_PATH=""
if [ -n "$FOLDER_PATH" ]; then
  FINAL_PATH="${TEAM_NAME}/${FOLDER_PATH}"
else
  # Jika di DEV dia ada di luar folder, di PROD dia akan masuk ke dalam folder Tim-nya
  FINAL_PATH="${TEAM_NAME}"
fi

# Simpan hasil string path final ke sidecar file metadata (.meta)
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

    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
      "docker exec '$DEV_CONTAINER' sh -lc 'n8n export:workflow --id \"$sub_id\" --output /tmp/n8n-git/${sub_id}.json --pretty'"
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
      "docker exec '$DEV_CONTAINER' cat '/tmp/n8n-git/${sub_id}.json'" > "${TMP_DIR}/${sub_id}.json"
    jq -S '.' "${TMP_DIR}/${sub_id}.json" > "${OUT_DIR}/${sub_id}.json"
    echo "    Exported sub-workflow: ${OUT_DIR}/${sub_id}.json"
  done
fi
