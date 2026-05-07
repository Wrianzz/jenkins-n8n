#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: validate-dev-credentials.sh <WORKFLOW_ID> [WORKFLOW_FILE] [SUB_WORKFLOW_IDS_CSV]}"
WORKFLOW_FILE="${2:-workflows/${WORKFLOW_ID}.json}"
SUB_WORKFLOW_IDS_CSV="${3:-}"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "[ERR] Workflow file not found in checked-out branch: $WORKFLOW_FILE"
  exit 1
fi

echo "[START] Validate workflow credentials naming from branch file"
if ! INVALID_CREDENTIAL_NODES="$(jq -r '
  def workflow_objects:
    if type == "array" then .[] else . end;

  workflow_objects
  | .nodes[]?
  | select((.credentials? | type) == "object") as $node
  | ($node.credentials | to_entries[]?) as $cred
  | ($cred.value.name // "") as $credName
  | select(($credName | test("-production$"; "i")) | not)
  | "- node=\($node.name // "<unnamed>") credentialType=\($cred.key) credentialName=\($credName)"
' "$WORKFLOW_FILE")"; then
  echo "[ERR] Failed to parse workflow JSON structure while validating credentials: $WORKFLOW_FILE"
  exit 1
fi

if [[ -n "$INVALID_CREDENTIAL_NODES" ]]; then
  echo "[ERR] Found non-production credential name(s)."
  echo "[ERR] Every credential in workflow must use the format: <Nama-kredensial>-Production (case-insensitive)."
  echo "$INVALID_CREDENTIAL_NODES"
  exit 1
fi

echo "[OK] All node credentials already use suffix -Production (case-insensitive)."

if [[ -n "$SUB_WORKFLOW_IDS_CSV" ]]; then
  # Support both comma-separated and whitespace-separated IDs from callers.
  SUB_WORKFLOW_IDS_NORMALIZED="$(echo "$SUB_WORKFLOW_IDS_CSV" | tr ',\n\r\t' '    ')"
  for sub_id_raw in $SUB_WORKFLOW_IDS_NORMALIZED; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue

    sub_file="workflows/${sub_id}.json"
    if [[ ! -f "$sub_file" ]]; then
      echo "[ERR] Sub-workflow file not found in checked-out branch: $sub_file"
      exit 1
    fi

    echo "[START] Validate sub-workflow credentials naming: ${sub_id}"
    if ! INVALID_SUB_CREDENTIAL_NODES="$(jq -r '
      def workflow_objects:
        if type == "array" then .[] else . end;

      workflow_objects
      | .nodes[]?
      | select((.credentials? | type) == "object") as $node
      | ($node.credentials | to_entries[]?) as $cred
      | ($cred.value.name // "") as $credName
      | select(($credName | test("-production$"; "i")) | not)
      | "- node=\($node.name // "<unnamed>") credentialType=\($cred.key) credentialName=\($credName)"
    ' "$sub_file")"; then
      echo "[ERR] Failed to parse workflow JSON structure while validating credentials: $sub_file"
      exit 1
    fi

    if [[ -n "$INVALID_SUB_CREDENTIAL_NODES" ]]; then
      echo "[ERR] Found non-production credential name(s) in sub-workflow ${sub_id}."
      echo "$INVALID_SUB_CREDENTIAL_NODES"
      exit 1
    fi
    echo "[OK] Sub-workflow ${sub_id} credentials valid."
  done
fi
