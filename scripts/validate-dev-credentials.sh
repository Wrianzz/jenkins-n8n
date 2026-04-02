#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: validate-dev-credentials.sh <WORKFLOW_ID> [WORKFLOW_FILE]}"
WORKFLOW_FILE="${2:-workflows/${WORKFLOW_ID}.json}"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "[ERR] Workflow file not found in checked-out branch: $WORKFLOW_FILE"
  exit 1
fi

echo "[0] Validate workflow credentials naming from branch file"
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
