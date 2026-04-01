#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_ID="${1:?usage: validate-dev-credentials.sh <WORKFLOW_ID>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_FILE="${REPO_ROOT}/workflows/${WORKFLOW_ID}.json"

EXPORT_SCRIPT="${REPO_ROOT}/scripts/export-to-git.sh"

[[ -x "$EXPORT_SCRIPT" ]] || { echo "[ERR] export script not executable: $EXPORT_SCRIPT"; exit 1; }

echo "[0] Export workflow from DEV"
"$EXPORT_SCRIPT" "$WORKFLOW_ID"

[[ -f "$WF_FILE" ]] || { echo "[ERR] Workflow file not found after export: $WF_FILE"; exit 1; }

echo "[1] Validate workflow credentials naming"
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
' "$WF_FILE")"; then
  echo "[ERR] Failed to parse workflow JSON structure while validating credentials: $WF_FILE"
  exit 1
fi

if [[ -n "$INVALID_CREDENTIAL_NODES" ]]; then
  echo "[ERR] Found non-production credential name(s)."
  echo "[ERR] Every credential in workflow must use the format: <Nama-kredensial>-Production (case-insensitive)."
  echo "$INVALID_CREDENTIAL_NODES"
  exit 1
fi

echo "[OK] All node credentials already use suffix -Production (case-insensitive)."
