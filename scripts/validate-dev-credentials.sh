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
      (.nodeName | type) == "string" and (.nodeName | length) > 0 and
      (.credentialType | type) == "string" and (.credentialType | length) > 0 and
      (.credentialName | type) == "string" and (.credentialName | length) > 0 and
      (.credentialId | type) == "string" and (.credentialId | length) > 0
    ))
  ' "$map_path" >/dev/null; then
    echo "[ERR] Invalid credential map schema: $map_path"
    echo "[ERR] Expected format: {\"entries\":[{\"nodeName\":\"...\",\"credentialType\":\"...\",\"credentialName\":\"...\",\"credentialId\":\"...\"}]}"
    exit 1
  fi

  echo "[OK] Credential map schema valid: $(basename "$map_path")"
}

validate_workflow_nodes_against_map() {
  local workflow_file="$1"
  local map_file="$2"

  if ! jq -e --slurpfile mapping "$map_file" '
    def entries: (($mapping[0] // {}) | .entries // []);

    def wf_nodes:
      if type == "array" then
        [ .[] | select(type == "object") | .nodes[]? ]
      else
        [ if type == "object" then .nodes[]? else empty end ]
      end;

    def trim: tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def norm_name: trim | ascii_downcase | gsub("[[:space:]]+"; " ");

    def node_for_entry($entry):
      ($entry.nodeName // "" | norm_name) as $wanted_name
      | ($entry.nodeId? // "" | trim) as $wanted_id
      | wf_nodes as $all
      | ($all | map(select((.name // "" | norm_name) == $wanted_name))) as $by_name
      | if ($by_name | length) > 0 then
          $by_name[0]
        elif ($wanted_id | length) > 0 then
          ($all | map(select((.id // "" | trim) == $wanted_id)))[0]
        else
          empty
        end;

    def node_exists($entry):
      (node_for_entry($entry) | type) == "object";

    def cred_exists($entry; $cred_type):
      node_for_entry($entry)
      | (.credentials? | type) == "object" and ((.credentials[$cred_type]? | type) == "object");

    reduce entries[] as $entry (true;
      if (node_exists($entry) | not) then
        error("Node \($entry.nodeName) gaada. Pastikan nodeName di credential map sama persis (abaikan kapital/spasi).")
      elif (cred_exists($entry; $entry.credentialType) | not) then
        error("Node \($entry.nodeName) tidak punya credential type \($entry.credentialType). Silakan hubungi tim DevOps.")
      else
        .
      end
    )
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
