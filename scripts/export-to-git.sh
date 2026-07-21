#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: export-to-git.sh <WORKFLOW_ID> [SUB_WORKFLOW_IDS_CSV]}"
SUB_WORKFLOW_IDS_CSV="${2:-}"

DEV_SSH_HOST="${DEV_SSH_HOST:?DEV_SSH_HOST is required}"
DEV_SSH_USER="${DEV_SSH_USER:-}"
DEV_SSH_PORT="${DEV_SSH_PORT:-22}"
DEV_CONTAINER="${DEV_CONTAINER:-n8n-dev-n8n-dev-1}"
DEV_PG_CONTAINER="${DEV_PG_CONTAINER:-n8n-dev-postgres-dev-1}"
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

export_workflow_folder_path() {
  local workflow_id="$1"
  local out_file="${OUT_DIR}/folder-maps/${workflow_id}.folder.json"

  mkdir -p "${OUT_DIR}/folder-maps"

  echo "    Export folder path metadata for workflow: ${workflow_id}"

  local folders_supported
  folders_supported="$(
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "docker exec '$DEV_PG_CONTAINER' psql -U n8n -d n8n -tA -v ON_ERROR_STOP=1 -c \"
      select case when
        to_regclass('\''public.folder'\'') is not null
        and exists (
          select 1 from information_schema.columns
          where table_name = '\''workflow_entity'\'' and column_name = '\''parentFolderId'\''
        )
        then '\''1'\'' else '\''0'\'' end;
    \"" 2>/dev/null | tr -d '\r' | tail -n 1 || true
  )"

  if [[ "$folders_supported" != "1" ]]; then
    jq -n -S '{path: []}' > "$out_file"
    echo "    SKIP: DEV n8n folder schema not found; wrote empty folder metadata"
    echo "    Folder metadata: ${out_file}"
    return 0
  fi

  local folder_json
  folder_json="$(
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "docker exec '$DEV_PG_CONTAINER' psql -U n8n -d n8n -tA -v ON_ERROR_STOP=1 -c \"
      with recursive folder_tree as (
        select f.id, f.name, f.\"parentFolderId\", array[f.name]::text[] as path
        from folder f
        where f.\"parentFolderId\" is null
        union all
        select child.id, child.name, child.\"parentFolderId\", parent.path || child.name
        from folder child
        join folder_tree parent on child.\"parentFolderId\" = parent.id
      )
      select coalesce(jsonb_build_object('\''path'\'', ft.path)::text, '\''{\"path\":[]}'\'')
      from workflow_entity w
      left join folder_tree ft on ft.id = w.\"parentFolderId\"
      where w.id = '\''${workflow_id}'\'';
    \"" 2>/dev/null | tr -d '\r' | tail -n 1 || true
  )"

  if [[ -z "$folder_json" ]] || ! jq -e '.path | type == "array"' >/dev/null 2>&1 <<< "$folder_json"; then
    jq -n -S '{path: []}' > "$out_file"
    echo "    WARN: folder metadata unavailable; wrote empty folder path"
  else
    jq -S '.' <<< "$folder_json" > "$out_file"
  fi

  echo "    Folder metadata: ${out_file}"
}

echo "[1] Export main workflow on DEV server"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' sh -lc 'rm -rf /tmp/n8n-git && mkdir -p /tmp/n8n-git && n8n export:workflow --id \"$WORKFLOW_ID\" --output /tmp/n8n-git/${WORKFLOW_ID}.json --pretty'"

echo "[2] Copy exported file from DEV server"
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" \
  "docker exec '$DEV_CONTAINER' cat '/tmp/n8n-git/${WORKFLOW_ID}.json'" > "$LOCAL_FILE"

echo "[3] Normalize JSON for cleaner diffs"
jq -S '.' "$LOCAL_FILE" > "${OUT_DIR}/${WORKFLOW_ID}.json"

echo "[4] Done: ${OUT_DIR}/${WORKFLOW_ID}.json"
export_workflow_folder_path "$WORKFLOW_ID"

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
    export_workflow_folder_path "$sub_id"
  done
fi
