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

  echo "[DEBUG] Credential map file: $map_path"
  echo "[DEBUG] Credential map content:"
  cat "$map_path"
  echo ""

  if ! jq -e '
    (.entries | type) == "array" and
    (.entries | length) > 0 and
    (all(.entries[];
      (.nodeName | type) == "string" and (.nodeName | length) > 0 and
      (.credentialName | type) == "string" and (.credentialName | length) > 0 and
      (.credentialId | type) == "string" and (.credentialId | length) > 0
    ))
  ' "$map_path" >/dev/null; then
    echo "[ERR] Invalid credential map schema: $map_path"
    echo "[ERR] Expected format:"
    echo '{"entries":[{"nodeName":"...","credentialName":"...","credentialId":"..."}]}'
    echo ""
    echo "[NOTE] credentialType sudah tidak wajib karena akan otomatis diambil dari workflow JSON."
    exit 1
  fi

  echo "[OK] Credential map schema valid: $(basename "$map_path")"
}

validate_workflow_nodes_against_map() {
  local workflow_file="$1"
  local map_file="$2"

  echo "[DEBUG] Workflow file: $workflow_file"
  echo "[DEBUG] Credential map file: $map_file"

  local validation_output

  if ! validation_output="$(jq -r \
    --arg workflow_file "$workflow_file" \
    --arg map_file "$map_file" \
    --slurpfile mapping "$map_file" '
    def entries: (($mapping[0] // {}) | .entries // []);

    def wf_nodes:
      if type == "array" then
        [ .[] | select(type == "object") | .nodes[]? ]
      elif type == "object" then
        [ .nodes[]? ]
      else
        []
      end;

    def trim:
      tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");

    def norm_name:
      trim | ascii_downcase | gsub("[[:space:]]+"; " ");

    def credential_keys($node):
      (($node.credentials // {}) | keys);

    def node_for_entry($entry; $nodes):
      ($entry.nodeName // "" | norm_name) as $wanted_name
      | ($entry.nodeId? // "" | trim) as $wanted_id
      | ($nodes | map(select((.name // "" | norm_name) == $wanted_name))) as $by_name
      | if ($by_name | length) > 0 then
          $by_name[0]
        elif ($wanted_id | length) > 0 then
          (($nodes | map(select((.id // "" | trim) == $wanted_id)))[0] // null)
        else
          null
        end;

    def candidates($entry; $nodes):
      ($entry.nodeName // "" | norm_name) as $wanted
      | $nodes
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

    wf_nodes as $nodes
    | entries as $entries
    | [
        $entries[]
        | . as $entry
        | (node_for_entry($entry; $nodes)) as $node
        | if ($node | type) != "object" then
            {
              type: "missing_node",
              entry: $entry,
              normalizedNodeName: ($entry.nodeName // "" | norm_name),
              candidates: candidates($entry; $nodes)
            }
          elif ((credential_keys($node) | length) == 0) then
            {
              type: "missing_credentials_object",
              entry: $entry,
              matchedNode: {
                name: ($node.name // ""),
                id: ($node.id // ""),
                type: ($node.type // ""),
                credentialsObject: ($node.credentials // {})
              }
            }
          elif ((credential_keys($node) | length) > 1 and (($entry.credentialType? // "") | length) == 0) then
            {
              type: "multiple_credential_types",
              entry: $entry,
              matchedNode: {
                name: ($node.name // ""),
                id: ($node.id // ""),
                type: ($node.type // ""),
                credentialKeys: credential_keys($node),
                credentialsObject: ($node.credentials // {})
              }
            }
          elif ((($entry.credentialType? // "") | length) > 0 and ((($node.credentials // {})[$entry.credentialType] | type) != "object")) then
            {
              type: "optional_credential_type_mismatch",
              entry: $entry,
              matchedNode: {
                name: ($node.name // ""),
                id: ($node.id // ""),
                type: ($node.type // ""),
                credentialKeys: credential_keys($node),
                credentialsObject: ($node.credentials // {})
              }
            }
          else
            empty
          end
      ] as $problems

    | if ($problems | length) > 0 then
        "[DEBUG] Workflow file: \($workflow_file)",
        "[DEBUG] Credential map file: \($map_file)",
        "[DEBUG] Total workflow nodes: \($nodes | length)",
        "[DEBUG] Total mapping entries: \($entries | length)",
        "",
        "[DEBUG] Mapping entries:",
        (
          $entries[]
          | "  - nodeName=\"\(.nodeName // "")\" | credentialName=\"\(.credentialName // "")\" | credentialId=\"\(.credentialId // "")\" | optional credentialType=\"\(.credentialType // "(auto)")\""
        ),
        "",
        "[DEBUG] Workflow nodes + credential keys:",
        (
          $nodes[]
          | "  - name=\"\(.name // "")\" | id=\"\(.id // "")\" | type=\"\(.type // "")\" | credentials=[\((.credentials // {} | keys) | join(", "))]"
        ),
        "",
        "[FAIL] Found \($problems | length) validation problem(s):",
        (
          $problems[]
          | if .type == "missing_node" then
              "  [MISSING NODE]\n" +
              "    map.nodeName            : \"\(.entry.nodeName // "")\"\n" +
              "    normalized map.nodeName : \"\(.normalizedNodeName)\"\n" +
              "    candidate similar nodes : \(
                if (.candidates | length) > 0 then
                  (.candidates | join(" | "))
                else
                  "(tidak ada kandidat mirip)"
                end
              )"
            elif .type == "missing_credentials_object" then
              "  [NODE HAS NO CREDENTIAL]\n" +
              "    map.nodeName        : \"\(.entry.nodeName // "")\"\n" +
              "    matched node        : \"\(.matchedNode.name)\"\n" +
              "    matched node id     : \"\(.matchedNode.id)\"\n" +
              "    matched node type   : \"\(.matchedNode.type)\"\n" +
              "    raw credentials     : \(.matchedNode.credentialsObject | @json)"
            elif .type == "multiple_credential_types" then
              "  [MULTIPLE CREDENTIAL TYPES]\n" +
              "    map.nodeName              : \"\(.entry.nodeName // "")\"\n" +
              "    matched node              : \"\(.matchedNode.name)\"\n" +
              "    available credentialTypes : [\(.matchedNode.credentialKeys | join(", "))]\n" +
              "    hint                       : node ini punya lebih dari 1 credential key, jadi tambahkan credentialType khusus untuk entry ini."
            elif .type == "optional_credential_type_mismatch" then
              "  [OPTIONAL CREDENTIAL TYPE MISMATCH]\n" +
              "    map.nodeName              : \"\(.entry.nodeName // "")\"\n" +
              "    matched node              : \"\(.matchedNode.name)\"\n" +
              "    credentialType di map     : \"\(.entry.credentialType // "")\"\n" +
              "    available credentialTypes : [\(.matchedNode.credentialKeys | join(", "))]\n" +
              "    hint                       : hapus credentialType dari map, atau isi sesuai salah satu available credentialTypes."
            else
              "  [UNKNOWN PROBLEM] \(. | @json)"
            end
        ),
        "",
        "[HINT] Sekarang credentialType tidak wajib.",
        "[HINT] Script akan otomatis mengambil credential key dari workflow JSON, misalnya discordBotApi/postgres.",
        (null | halt_error(1))
      else
        "[DEBUG] Inferred credential mapping:",
        (
          $entries[]
          | . as $entry
          | (node_for_entry($entry; $nodes)) as $node
          | (credential_keys($node)) as $keys
          | (
              if (($entry.credentialType? // "") | length) > 0 then
                $entry.credentialType
              else
                $keys[0]
              end
            ) as $inferred_type
          | "  - nodeName=\"\($entry.nodeName)\" | inferredCredentialType=\"\($inferred_type)\" | newCredentialName=\"\($entry.credentialName)\" | newCredentialId=\"\($entry.credentialId)\""
        ),
        "[OK] Workflow nodes/credentials match map: \($workflow_file | split("/") | last)"
      end
  ' "$workflow_file" 2>&1)"; then
    echo "$validation_output"
    echo "[ERR] Workflow and map validation failed for: $workflow_file"
    exit 1
  fi

  echo "$validation_output"
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
