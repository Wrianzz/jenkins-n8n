#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: validate-dev-credentials.sh <WORKFLOW_ID> [WORKFLOW_FILE] [SUB_WORKFLOW_IDS_CSV]}"
WORKFLOW_FILE="${2:-workflows/${WORKFLOW_ID}.json}"
SUB_WORKFLOW_IDS_CSV="${3:-}"
MAP_DIR="workflows/credential-maps"

validate_credential_map_schema() {
  local map_path="$1"

  [[ -f "$map_path" ]] || {
    echo "[ERR] Credential map file not found: $map_path"
    exit 1
  }

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

  echo "[OK] Credential map schema valid: $(basename "$map_path")"
}

validate_workflow_nodes_against_map() {
  local workflow_file="$1"
  local map_file="$2"

  if ! jq -e --slurpfile mapping "$map_file" '
    def entries: (($mapping[0] // {}) | .entries // []);

    def node_exists($node_id):
      ((.nodes // []) | any(.id == $node_id));

    def cred_exists($node_id; $cred_type):
      ((.nodes // [])
       | map(select(.id == $node_id))[0]
       | (.credentials? | type) == "object" and ((.credentials[$cred_type]? | type) == "object"));

    if type == "array" then
      error("Array workflow format is not supported in validation script. Silakan hubungi tim DevOps.")
    else
      reduce entries[] as $entry (true;
        if (node_exists($entry.nodeId) | not) then
          error("Node \($entry.nodeName) dengan id \($entry.nodeId) gaada. Silakan hubungi tim DevOps.")
        elif (cred_exists($entry.nodeId; $entry.credentialType) | not) then
          error("Node \($entry.nodeName) dengan id \($entry.nodeId) tidak punya credential type \($entry.credentialType). Silakan hubungi tim DevOps.")
        else
          .
        end
      )
    end
  ' "$workflow_file" >/dev/null; then
    echo "[ERR] Workflow and map validation failed for: $workflow_file"
    exit 1
  fi

  echo "[OK] Workflow nodes/credentials match map: $(basename "$workflow_file")"
}

validate_one_workflow() {
  local workflow_file="$1"

  [[ -f "$workflow_file" ]] || {
    echo "[ERR] Workflow file not found in checked-out branch: $workflow_file"
    exit 1
  }

  local workflow_base
  workflow_base="$(basename "${workflow_file%.json}")"
  local map_file="${MAP_DIR}/${workflow_base}.credentials.json"

  echo "[START] Validate credential map for ${workflow_base}"
  validate_credential_map_schema "$map_file"
  validate_workflow_nodes_against_map "$workflow_file" "$map_file"
}

validate_one_workflow "$WORKFLOW_FILE"

if [[ -n "$SUB_WORKFLOW_IDS_CSV" ]]; then
  SUB_WORKFLOW_IDS_NORMALIZED="$(echo "$SUB_WORKFLOW_IDS_CSV" | tr ',\n\r\t' '    ')"
  for sub_id_raw in $SUB_WORKFLOW_IDS_NORMALIZED; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue
    validate_one_workflow "workflows/${sub_id}.json"
  done
fi

echo "[OK] Credential mapping validation completed."
