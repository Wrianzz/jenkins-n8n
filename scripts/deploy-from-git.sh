#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/deploy-from-git.sh <WORKFLOW_ID> [SUB_WORKFLOW_IDS_CSV]
#   scripts/deploy-from-git.sh --file workflows/<something>.json
#   scripts/deploy-from-git.sh --validate-only <WORKFLOW_ID>
#   scripts/deploy-from-git.sh --validate-only --file workflows/<something>.json

PROD_SSH_HOST="${PROD_SSH_HOST:?PROD_SSH_HOST is required}"
PROD_SSH_USER="${PROD_SSH_USER:-}"
PROD_SSH_PORT="${PROD_SSH_PORT:-22}"
PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_PG_CONTAINER="${PROD_PG_CONTAINER:-n8n-prod-postgres-prod-1}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_DIR="${REPO_ROOT}/workflows"
EXTRACT_FILTER="${REPO_ROOT}/scripts/extract-cred-ids.jq"
PROMOTE_SCRIPT="${REPO_ROOT}/scripts/promote-creds.sh"

PROD_REMOTE="${PROD_SSH_USER:+${PROD_SSH_USER}@}${PROD_SSH_HOST}"
PROD_SSH_OPTS=( -p "$PROD_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
PROD_SCP_OPTS=( -P "$PROD_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
if [[ -n "$SSH_KEY_FILE" ]]; then
  PROD_SSH_OPTS+=( -i "$SSH_KEY_FILE" )
  PROD_SCP_OPTS+=( -i "$SSH_KEY_FILE" )
fi

VALIDATE_ONLY=0
if [[ "${1:-}" == "--validate-only" ]]; then
  VALIDATE_ONLY=1
  shift
fi

WF_FILE=""
if [[ "${1:-}" == "--file" ]]; then
  WF_FILE="${2:?usage: deploy-from-git.sh --file <path-to-json>}"
  [[ "$WF_FILE" = /* ]] || WF_FILE="${REPO_ROOT}/${WF_FILE}"
else
  WORKFLOW_ID="${1:?usage: deploy-from-git.sh <WORKFLOW_ID>}"
  SUB_WORKFLOW_IDS_CSV="${2:-}"
  WF_FILE="${WF_DIR}/${WORKFLOW_ID}.json"
fi

[[ -f "$WF_FILE" ]] || { echo "[ERR] Workflow file not found: $WF_FILE"; exit 1; }
[[ -f "$EXTRACT_FILTER" ]] || { echo "[ERR] jq filter not found: $EXTRACT_FILTER"; exit 1; }
[[ -x "$PROMOTE_SCRIPT" ]] || { echo "[ERR] promote script not executable: $PROMOTE_SCRIPT"; exit 1; }

collect_cred_ids_from_file() {
  local file_path="$1"
  jq -r -f "$EXTRACT_FILTER" "$file_path" 2>/dev/null | awk 'NF' | sort -u
}

validate_credential_suffix() {
  local file_path="$1"

  local invalid_nodes
  if ! invalid_nodes="$(jq -r '
    def workflow_objects:
      if type == "array" then .[] else . end;

    workflow_objects
    | .nodes[]?
    | select((.credentials? | type) == "object") as $node
    | ($node.credentials | to_entries[]?) as $cred
    | ($cred.value.name // "") as $credName
    | select(($credName | test("-production$"; "i")) | not)
    | "- node=\($node.name // "<unnamed>") credentialType=\($cred.key) credentialName=\($credName)"
  ' "$file_path")"; then
    echo "[ERR] Failed to parse workflow JSON structure while validating credentials: $file_path"
    exit 1
  fi

  if [[ -n "$invalid_nodes" ]]; then
    echo "[ERR] Found non-production credential name(s) in: $file_path"
    echo "[ERR] Every credential in workflow must use the format: <Nama-kredensial>-Production (case-insensitive)."
    echo "$invalid_nodes"
    exit 1
  fi

  echo "    OK: credential names in $(basename "$file_path") use suffix -Production (case-insensitive)."
}

echo "[0] Validate workflow credentials naming"
validate_credential_suffix "$WF_FILE"

if [[ -n "${SUB_WORKFLOW_IDS_CSV:-}" ]]; then
  IFS=',' read -r -a SUB_WORKFLOW_IDS <<< "$SUB_WORKFLOW_IDS_CSV"
  for sub_id_raw in "${SUB_WORKFLOW_IDS[@]}"; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue

    sub_file="${WF_DIR}/${sub_id}.json"
    if [[ ! -f "$sub_file" ]]; then
      echo "[WARN] Selected sub-workflow file not found in repo while validating credential naming: $sub_file"
      continue
    fi

    validate_credential_suffix "$sub_file"
  done
fi

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  echo "[OK] Validation only mode completed."
  exit 0
fi

PROD_PROJECT_ID="$(ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker exec '$PROD_PG_CONTAINER' psql -U n8n -d n8n -tA -c \"select id from project order by \\\"createdAt\\\" asc limit 1;\"" | tr -d '\r' | xargs)"
[[ -n "$PROD_PROJECT_ID" ]] || { echo "[ERR] PROD_PROJECT_ID not found"; exit 1; }

base="$(basename "$WF_FILE")"
remote_host_file="/tmp/${base}"
remote_container_file="/tmp/${base}"

echo "[1] Scan credential IDs from workflow(s)"

declare -a CRED_IDS=()

mapfile -t MAIN_CRED_IDS < <(collect_cred_ids_from_file "$WF_FILE")
if [[ "${#MAIN_CRED_IDS[@]}" -gt 0 ]]; then
  CRED_IDS+=("${MAIN_CRED_IDS[@]}")
fi

if [[ -n "${SUB_WORKFLOW_IDS_CSV:-}" ]]; then
  IFS=',' read -r -a SUB_WORKFLOW_IDS <<< "$SUB_WORKFLOW_IDS_CSV"
  for sub_id_raw in "${SUB_WORKFLOW_IDS[@]}"; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue

    sub_file="${WF_DIR}/${sub_id}.json"
    if [[ ! -f "$sub_file" ]]; then
      echo "[WARN] Selected sub-workflow file not found in repo while scanning credentials: $sub_file"
      continue
    fi

    mapfile -t SUB_CRED_IDS < <(collect_cred_ids_from_file "$sub_file")
    if [[ "${#SUB_CRED_IDS[@]}" -gt 0 ]]; then
      CRED_IDS+=("${SUB_CRED_IDS[@]}")
    fi
  done
fi

if [[ "${#CRED_IDS[@]}" -gt 0 ]]; then
  mapfile -t CRED_IDS < <(printf "%s\n" "${CRED_IDS[@]}" | awk 'NF' | sort -u)
fi

if [[ "${#CRED_IDS[@]}" -gt 0 ]]; then
  CRED_IDS_RAW="${CRED_IDS[*]}"
  echo "    Found ${#CRED_IDS[@]} credential ID(s) from main + selected sub-workflow(s): ${CRED_IDS_RAW}"
  echo "[2] Promote credentials to PROD"
  "$PROMOTE_SCRIPT" "$CRED_IDS_RAW"
else
  echo "    No credential IDs found in main/sub-workflow files; skip promote creds"
fi

echo "[3] Transfer and import workflow to PROD"

if [[ -n "${SUB_WORKFLOW_IDS_CSV:-}" ]]; then
  IFS=',' read -r -a SUB_WORKFLOW_IDS <<< "$SUB_WORKFLOW_IDS_CSV"
  for sub_id_raw in "${SUB_WORKFLOW_IDS[@]}"; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue

    sub_file="${WF_DIR}/${sub_id}.json"
    if [[ ! -f "$sub_file" ]]; then
      echo "[WARN] Selected sub-workflow file not found in repo: $sub_file. Skip push for this sub-workflow."
      continue
    fi

    sub_host_file="/tmp/${sub_id}.json"
    sub_container_file="/tmp/${sub_id}.json"
    echo "    Push selected sub-workflow: $sub_id"
    scp "${PROD_SCP_OPTS[@]}" "$sub_file" "$PROD_REMOTE:$sub_host_file"
    ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
      "docker cp '$sub_host_file' '$PROD_CONTAINER:$sub_container_file' && docker exec '$PROD_CONTAINER' n8n import:workflow --input '$sub_container_file' --projectId '$PROD_PROJECT_ID'"
    ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
      "docker exec '$PROD_CONTAINER' n8n publish:workflow --id='$sub_id'"
    ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
      "rm -f '$sub_host_file'; docker exec '$PROD_CONTAINER' sh -lc 'rm -f \"$sub_container_file\" || true'"
  done
fi

scp "${PROD_SCP_OPTS[@]}" "$WF_FILE" "$PROD_REMOTE:$remote_host_file"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker cp '$remote_host_file' '$PROD_CONTAINER:$remote_container_file' && docker exec '$PROD_CONTAINER' n8n import:workflow --input '$remote_container_file' --projectId '$PROD_PROJECT_ID'"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker exec '$PROD_CONTAINER' n8n publish:workflow --id='$WORKFLOW_ID'"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "rm -f '$remote_host_file'; docker exec '$PROD_CONTAINER' sh -lc 'rm -f \"$remote_container_file\" || true'"

echo "[4] Done"
