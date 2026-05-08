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
MAP_DIR="${REPO_ROOT}/workflows/credential-maps"

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

apply_production_credential_map() {
  local file_path="$1"
  local map_path="$2"

  [[ -f "$map_path" ]] || { echo "[ERR] Credential map file not found: $map_path"; exit 1; }

  local tmp_file
  tmp_file="$(mktemp)"

  if ! jq --argfile mapping "$map_path" '
    def entries: ($mapping.entries // []);

    def replace_node_credential($node; $entry):
      if ($node.id == $entry.nodeId)
      then
        if (($node.credentials? | type) != "object") then
          error("Node \($entry.nodeName) with id \($entry.nodeId) has no credentials object. Silakan hubungi tim DevOps.")
        elif ($node.credentials[$entry.credentialType]? | type) != "object" then
          error("Node \($entry.nodeName) with id \($entry.nodeId) missing credential type \($entry.credentialType). Silakan hubungi tim DevOps.")
        else
          $node
          | .credentials[$entry.credentialType].id = $entry.credentialId
          | .credentials[$entry.credentialType].name = $entry.credentialName
        end
      else $node end;

    def replace_all($wf):
      reduce entries[] as $entry ($wf;
        .nodes = ((.nodes // []) | map(replace_node_credential(.; $entry)))
      );

    def validate_presence($wf):
      reduce entries[] as $entry ([];
        . + (if (($wf.nodes // []) | any(.id == $entry.nodeId)) then [] else [$entry] end)
      );

    if (type == "array") then
      (map(replace_all(.))) as $result
      | (reduce $result[] as $wf ([]; . + validate_presence($wf))) as $missing
      | if ($missing | length) > 0 then
          error("Node \($missing[0].nodeName) dengan id \($missing[0].nodeId) gaada. Silakan hubungi tim DevOps.")
        else
          $result
        end
    else
      (replace_all(.)) as $result
      | (validate_presence($result)) as $missing
      | if ($missing | length) > 0 then
          error("Node \($missing[0].nodeName) dengan id \($missing[0].nodeId) gaada. Silakan hubungi tim DevOps.")
        else
          $result
        end
    end
  ' "$file_path" > "$tmp_file"; then
    rm -f "$tmp_file"
    echo "[ERR] Failed to apply credential map from $map_path to $file_path"
    exit 1
  fi

  mv "$tmp_file" "$file_path"
  echo "    OK: applied production credential map from $(basename "$map_path")"
}

validate_credential_map_schema() {
  local map_path="$1"

  if ! jq -e '
    (.entries | type) == "array" and
    (.entries | length) > 0 and
    (all(.entries[];
      (.nodeId | type) == "string" and (.nodeId | length) > 0 and
      (.nodeName | type) == "string" and (.nodeName | length) > 0 and
      (.credentialType | type) == "string" and (.credentialType | length) > 0 and
      (.credentialName | type) == "string" and (.credentialName | length) > 0 and
      (.credentialId | type) == "string" and (.credentialId | length) > 0
    ))
  ' "$map_path" >/dev/null; then
    echo "[ERR] Invalid credential map schema: $map_path"
    echo "[ERR] Expected format: {\"entries\":[{\"nodeId\":\"...\",\"nodeName\":\"...\",\"credentialType\":\"...\",\"credentialName\":\"...\",\"credentialId\":\"...\"}]}"
    exit 1
  fi
  echo "    OK: credential map schema valid in $(basename "$map_path")"
}

MAP_FILE="${MAP_DIR}/$(basename "${WF_FILE%.json}").credentials.json"

echo "[0] Validate and apply workflow credential mapping"
validate_credential_map_schema "$MAP_FILE"
apply_production_credential_map "$WF_FILE" "$MAP_FILE"

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

    sub_map_file="${MAP_DIR}/$(basename "${sub_file%.json}").credentials.json"
    validate_credential_map_schema "$sub_map_file"
    apply_production_credential_map "$sub_file" "$sub_map_file"
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
