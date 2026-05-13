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
apply_production_credential_map() {
  local file_path="$1"
  local map_path="$2"

  [[ -f "$map_path" ]] || {
    echo "[ERR] Credential map file not found: $map_path"
    exit 1
  }

  local tmp_file
  tmp_file="$(mktemp)"

  if ! jq --slurpfile mapping "$map_path" '
    def entries:
      (($mapping[0] // {}) | .entries // []);

    def trim:
      tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");

    def norm_name:
      trim | ascii_downcase | gsub("[[:space:]]+"; " ");

    def all_nodes($root):
      if ($root | type) == "array" then
        [ $root[]? | select(type == "object") | .nodes[]? ]
      elif ($root | type) == "object" then
        [ $root.nodes[]? ]
      else
        []
      end;

    def credential_keys($node):
      (($node.credentials // {}) | keys);

    def node_matches_entry($node; $entry):
      ($entry.nodeId? // "" | trim) as $wanted_id
      | ($entry.nodeName // "" | norm_name) as $wanted_name
      | if ($wanted_id | length) > 0 then
          (($node.id // "" | trim) == $wanted_id)
        else
          (($node.name // "" | norm_name) == $wanted_name)
        end;

    def candidate_nodes($root; $entry):
      ($entry.nodeName // "" | norm_name) as $wanted
      | all_nodes($root)
      | map(.name // "")
      | map(select(
          (. | norm_name) as $n
          | ($wanted | length) > 0
          and ($n | length) > 0
          and (
            ($n | contains($wanted))
            or
            ($wanted | contains($n))
          )
        ))
      | .[0:10];

    def credential_key_for_entry($root; $entry):
      (all_nodes($root) | map(select(node_matches_entry(.; $entry)))) as $matches
      | if ($matches | length) == 0 then
          error(
            "Node \($entry.nodeName) gaada di workflow. " +
            "Candidate similar nodes: " +
            (
              candidate_nodes($root; $entry)
              | if length > 0 then join(" | ") else "(tidak ada kandidat mirip)" end
            )
          )
        elif ($matches | length) > 1 then
          error(
            "Node \($entry.nodeName) match lebih dari satu node. " +
            "Tambahkan nodeId di credential map supaya tidak ambigu."
          )
        else
          $matches[0] as $node
          | credential_keys($node) as $keys
          | ($entry.credentialType? // "" | trim) as $wanted_type

          | if ($keys | length) == 0 then
              error(
                "Node \($entry.nodeName) tidak punya credentials object. " +
                "Node type: \($node.type // "-")"
              )

            elif ($keys | length) == 1 then
              $keys[0]

            elif (($wanted_type | length) > 0) and (($node.credentials[$wanted_type]? | type) == "object") then
              $wanted_type

            elif ($wanted_type | length) > 0 then
              error(
                "credentialType di map tidak cocok untuk node \($entry.nodeName). " +
                "credentialType map: \($wanted_type). " +
                "Available credentialTypes: [\($keys | join(", "))]"
              )

            else
              error(
                "Node \($entry.nodeName) punya lebih dari 1 credential key: [\($keys | join(", "))]. " +
                "Tambahkan credentialType khusus untuk entry ini."
              )
            end
        end;

    def replace_node_credential($node; $entry; $cred_key):
      if node_matches_entry($node; $entry) then
        if (($node.credentials? | type) != "object") then
          error("Node \($entry.nodeName) has no credentials object.")
        elif (($node.credentials[$cred_key]? | type) != "object") then
          error("Node \($entry.nodeName) missing credential key \($cred_key).")
        else
          $node
          | .credentials[$cred_key].id = $entry.credentialId
          | .credentials[$cred_key].name = $entry.credentialName
        end
      else
        $node
      end;

    def apply_entry($entry):
      . as $root
      | credential_key_for_entry($root; $entry) as $cred_key
      | if ($root | type) == "array" then
          map(
            if type == "object" then
              .nodes = ((.nodes // []) | map(replace_node_credential(.; $entry; $cred_key)))
            else
              .
            end
          )
        elif ($root | type) == "object" then
          .nodes = ((.nodes // []) | map(replace_node_credential(.; $entry; $cred_key)))
        else
          error("Workflow JSON root harus object atau array.")
        end;

    reduce entries[] as $entry (.;
      apply_entry($entry)
    )
  ' "$file_path" > "$tmp_file"; then
    rm -f "$tmp_file"
    echo "[ERR] Failed to apply credential map from $map_path to $file_path"
    exit 1
  fi

  mv "$tmp_file" "$file_path"

  echo "    OK: applied production credential map from $(basename "$map_path")"

  echo "    Applied credential entries:"
  jq -r --slurpfile mapping "$map_path" '
    def entries:
      (($mapping[0] // {}) | .entries // []);

    entries[]
    | "      - nodeName=\"\(.nodeName)\" -> credentialName=\"\(.credentialName)\" credentialId=\"\(.credentialId)\""
  ' "$file_path" || true
}

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
      (.credentialName | type) == "string" and (.credentialName | length) > 0 and
      (.credentialId | type) == "string" and (.credentialId | length) > 0 and

      (
        (has("nodeId") | not)
        or
        (.nodeId | type) == "string" and (.nodeId | length) > 0
      ) and

      (
        (has("credentialType") | not)
        or
        (.credentialType | type) == "string" and (.credentialType | length) > 0
      )
    ))
  ' "$map_path" >/dev/null; then
    echo "[ERR] Invalid credential map schema: $map_path"
    echo "[ERR] Expected format:"
    echo '{"entries":[{"nodeName":"...","credentialName":"...","credentialId":"..."}]}'
    echo ""
    echo "[NOTE] nodeId optional."
    echo "[NOTE] credentialType optional. Kalau tidak ada, akan otomatis diambil dari workflow JSON."
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

echo "[1] Skip credential promotion (mapping-only deployment)"

echo "[2] Transfer and import workflow to PROD"

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
      "docker cp '$sub_host_file' '$PROD_CONTAINER:$sub_container_file' && docker exec -u 0 '$PROD_CONTAINER' n8n import:workflow --input '$sub_container_file' --projectId '$PROD_PROJECT_ID'"
    ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
      "docker exec '$PROD_CONTAINER' n8n publish:workflow --id='$sub_id'"
    ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
      "rm -f '$sub_host_file'; docker exec '$PROD_CONTAINER' sh -lc 'rm -f \"$sub_container_file\" || true'"
  done
fi

scp "${PROD_SCP_OPTS[@]}" "$WF_FILE" "$PROD_REMOTE:$remote_host_file"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker cp '$remote_host_file' '$PROD_CONTAINER:$remote_container_file' && docker exec -u 0 '$PROD_CONTAINER' n8n import:workflow --input '$remote_container_file' --projectId '$PROD_PROJECT_ID'"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "docker exec '$PROD_CONTAINER' n8n publish:workflow --id='$WORKFLOW_ID'"
ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
  "rm -f '$remote_host_file'; docker exec '$PROD_CONTAINER' sh -lc 'rm -f \"$remote_container_file\" || true'"

echo "[3] Done"
