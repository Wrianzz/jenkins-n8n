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
PROD_DEPLOY_TARGET="${PROD_DEPLOY_TARGET:-kubernetes}"
PROD_CONTAINER="${PROD_CONTAINER:-n8n-prod-n8n-prod-1}"
PROD_K8S_NAMESPACE="${PROD_K8S_NAMESPACE:-default}"
PROD_K8S_POD_SELECTOR="${PROD_K8S_POD_SELECTOR:-app=n8n}"
PROD_K8S_CONTAINER="${PROD_K8S_CONTAINER:-}"
PROD_PG_HOST="${PROD_PG_HOST:?PROD_PG_HOST is required}"
PROD_PG_PORT="${PROD_PG_PORT:-5432}"
PROD_PG_DATABASE="${PROD_PG_DATABASE:-n8n}"
PROD_PG_USER="${PROD_PG_USER:-n8n}"
PROD_PG_PASSWORD="${PROD_PG_PASSWORD:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
PROD_KUBECONFIG="${PROD_KUBECONFIG:-/var/jenkins_home/n8n/kubeconfig-88.88}"

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

remote_quote() {
  printf "%q" "$1"
}

remote_psql() {
  local sql="$1"

  # Karena server PostgreSQL terpisah dan bisa ditembak langsung dari Jenkins,
  # kita hilangkan SSH / wrapper pod. Jalankan langsung via psql lokal Jenkins.
  PGPASSWORD="$PROD_PG_PASSWORD" psql \
    -h "$PROD_PG_HOST" \
    -p "$PROD_PG_PORT" \
    -U "$PROD_PG_USER" \
    -d "$PROD_PG_DATABASE" \
    -tA -c "$sql"
}

prod_kubectl_exec_prefix() {
  local pod_cmd container_arg
  pod_cmd="kubectl -n $(remote_quote "$PROD_K8S_NAMESPACE") get pod -l $(remote_quote "$PROD_K8S_POD_SELECTOR") -o jsonpath='{.items[0].metadata.name}'"
  container_arg=""
  if [[ -n "$PROD_K8S_CONTAINER" ]]; then
    container_arg="-c $(remote_quote "$PROD_K8S_CONTAINER")"
  fi

  printf "pod=\\$(%s); test -n \\\"\\$pod\\\"; kubectl -n %s exec \\\"\\$pod\\\" %s --" \
    "$pod_cmd" "$(remote_quote "$PROD_K8S_NAMESPACE")" "$container_arg"
}

n8n_exec() {
  local inner="$1"

  case "$PROD_DEPLOY_TARGET" in
    docker)
      ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
        "docker exec '$PROD_CONTAINER' sh -lc $(remote_quote "$inner")"
      ;;
    kubernetes|kubectl)
      # Menggunakan pembungkus deployment/n8n-main sesuai pod testing kamu
      kubectl --kubeconfig="$PROD_KUBECONFIG" exec deploy/n8n-main \
        -n "$PROD_K8S_NAMESPACE" \
        ${PROD_K8S_CONTAINER:+-c $PROD_K8S_CONTAINER} -- sh -lc "$inner"
      ;;
    *)
      echo "[ERR] Unsupported PROD_DEPLOY_TARGET: $PROD_DEPLOY_TARGET"
      exit 1
      ;;
  esac
}

VALIDATE_ONLY=0

if [[ "${1:-}" == "--validate-only" ]]; then
  VALIDATE_ONLY=1
  shift
fi

WF_FILE=""
SUB_WORKFLOW_IDS_CSV="${SUB_WORKFLOW_IDS_CSV:-}"

if [[ "${1:-}" == "--file" ]]; then
  WF_FILE="${2:?usage: deploy-from-git.sh --file <path-to-json>}"
  [[ "$WF_FILE" = /* ]] || WF_FILE="${REPO_ROOT}/${WF_FILE}"
  WORKFLOW_ID="$(basename "${WF_FILE%.json}")"
  SUB_WORKFLOW_IDS_CSV="${3:-}"
else
  WORKFLOW_ID="${1:?usage: deploy-from-git.sh <WORKFLOW_ID>}"
  SUB_WORKFLOW_IDS_CSV="${2:-}"
  WF_FILE="${WF_DIR}/${WORKFLOW_ID}.json"
fi

[[ -f "$WF_FILE" ]] || {
  echo "[ERR] Workflow file not found: $WF_FILE"
  exit 1
}

workflow_has_credentials() {
  local workflow_file="$1"

  jq -e '
    def wf_nodes:
      if type == "array" then
        [ .[] | select(type == "object") | .nodes[]? ]
      elif type == "object" then
        [ .nodes[]? ]
      else
        []
      end;

    (
      wf_nodes
      | map(select(
          (.credentials? | type) == "object"
          and
          ((.credentials // {}) | keys | length) > 0
        ))
      | length
    ) > 0
  ' "$workflow_file" >/dev/null 2>&1
}

sync_and_move_to_prod_folder() {
  local wf_id="$1"
  local meta_file="${REPO_ROOT}/workflows/metadata/${wf_id}.meta"

  if [ ! -f "$meta_file" ]; then
    echo "    [INFO] No folder metadata found for ${wf_id}. Staying at Root."
    return 0
  fi

  local target_path
  target_path=$(cat "$meta_file" | xargs)

  if [ -z "$target_path" ]; then
    echo "    [INFO] Folder metadata is empty for ${wf_id}. Staying at Root."
    return 0
  fi

  if [ -z "${PROD_PROJECT_ID:-}" ]; then
    PROD_PROJECT_ID="$(remote_psql 'select id from project order by "createdAt" asc limit 1;' | tr -d '\r' | xargs)"
  fi

  [[ -n "$PROD_PROJECT_ID" ]] || {
    echo "    [ERR] PROD_PROJECT_ID is empty inside folder sync function."
    exit 1
  }

  echo "    [PROCESS] Syncing folder structure to PROD: $target_path"

  IFS='/' read -r -a folders_array <<< "$target_path"
  local current_parent_id="null"

  for folder_name in "${folders_array[@]}"; do
    
    # 1. CEK FOLDER VIA DATABASE PROD (Bypass API n8n & WAF Cache)
    local check_query
    if [ "$current_parent_id" = "null" ]; then
      # PERBAIKAN: Gunakan \" biasa, jangan \\\"
      check_query="SELECT id FROM folder WHERE name = '${folder_name}' AND \"projectId\" = '${PROD_PROJECT_ID}' AND \"parentFolderId\" IS NULL LIMIT 1;"
    else
      # PERBAIKAN: Gunakan \" biasa, jangan \\\"
      check_query="SELECT id FROM folder WHERE name = '${folder_name}' AND \"projectId\" = '${PROD_PROJECT_ID}' AND \"parentFolderId\" = '${current_parent_id}' LIMIT 1;"
    fi

    local matched_id
    matched_id=$(remote_psql "$check_query" | tr -d '\r' | xargs)

    # 2. Jika ID kosong (folder benar-benar tidak ada di DB), buat via API POST
    if [ -z "$matched_id" ] || [ "$matched_id" = "null" ]; then
      echo "      Creating folder '$folder_name' under parent '$current_parent_id' in PROD..."
      local json_payload
      if [ "$current_parent_id" = "null" ]; then
        json_payload=$(jq -n --arg name "$folder_name" '{name: $name}')
      else
        json_payload=$(jq -n --arg name "$folder_name" --arg parent "$current_parent_id" '{name: $name, parentFolderId: $parent}')
      fi

      local create_res
      create_res=$(curl -s -k -X POST "${PROD_N8N_API_BASE_URL}/projects/${PROD_PROJECT_ID}/folders" \
        -H "X-N8N-API-KEY: ${PROD_N8N_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$json_payload")
      
      matched_id=$(echo "$create_res" | jq -r '.id // empty')
      
      if [ -z "$matched_id" ] || [ "$matched_id" = "null" ]; then
        echo "      [ERR] Failed to create folder. Response: $create_res"
        exit 1
      fi
    else
      # 3. Jika sudah ada di DB, lewati pembuatan & gunakan ID yang ditemukan
      echo "      Folder '$folder_name' already exists (ID: $matched_id). Reusing..."
    fi
    
    current_parent_id="$matched_id"
  done

  echo "      Moving workflow ${wf_id} into PROD folder ID: $current_parent_id via Database"
  local move_res
  move_res=$(remote_psql "UPDATE workflow_entity SET \"parentFolderId\" = '$current_parent_id' WHERE id = '${wf_id}' RETURNING id;" | tr -d '\r' | xargs)

  if [[ "$move_res" == *"UPDATE 1"* ]] || [[ "$move_res" == *"$wf_id"* ]]; then
    echo "    [OK] Successfully moved workflow ${wf_id} to '$target_path' in PROD."
  else
    echo "    [ERR] Failed to move workflow to folder via DB. Response: $move_res"
    exit 1
  fi
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
        ((.nodeId | type) == "string" and (.nodeId | length) > 0)
      ) and

      (
        (has("credentialType") | not)
        or
        ((.credentialType | type) == "string" and (.credentialType | length) > 0)
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

validate_and_apply_credential_map_if_needed() {
  local workflow_file="$1"
  local map_file="$2"

  local workflow_base
  workflow_base="$(basename "${workflow_file%.json}")"

  echo "    Check credential requirement for ${workflow_base}"

  if ! workflow_has_credentials "$workflow_file"; then
    echo "    SKIP: workflow has no credentials; credential map not required for ${workflow_base}"
    return 0
  fi

  validate_credential_map_schema "$map_file"
  apply_production_credential_map "$workflow_file" "$map_file"
}

inject_workflow_settings() {
  local target_file="$1"

  echo "    [PROCESS] Applying conditional fallback settings for $(basename "$target_file")"
  
  # Perbaikan filter jq untuk mendukung struktur root berupa Object maupun Array
  jq --arg ew "${PROD_ERROR_WORKFLOW_ID:-}" \
     --arg enable_ew "${ENABLE_ERROR_HANDLER:-false}" \
     --arg enable_timeout "${ENABLE_DEFAULT_TIMEOUT:-false}" \
     --argjson default_timeout 30 '
     
     # Fungsi pembantu untuk memanipulasi skema objek settings n8n
     def update_settings:
       .settings = (.settings // {})
       |
       # 1. Logika Timeout
       if .settings.executionTimeout == null and $enable_timeout == "true" then
         .settings.executionTimeout = $default_timeout
       else
         .
       end
       |
       # 2. Logika Error Workflow
       if .settings.errorWorkflow == null and $enable_ew == "true" and ($ew | length > 0) then
         .settings.errorWorkflow = $ew
       else
         .
       end;

     # Cek struktur root: jika array jalankan map update, jika object jalankan langsung
     if type == "array" then
       map(if type == "object" then update_settings else . end)
     elif type == "object" then
       update_settings
     else
       .
     end
     
  ' "$target_file" > "${target_file}.tmp" && mv "${target_file}.tmp" "$target_file"
}

prod_workflow_api() {
  local method="$1" path="$2" response_file="$3" payload="${4:-}" allow_missing="${5:-false}"
  local -a args=(
    --silent --show-error --insecure --connect-timeout 15 --max-time 120
    --output "$response_file" --write-out '%{http_code}' --request "$method"
    --header "X-N8N-API-KEY: ${PROD_N8N_API_KEY}"
    --header 'Accept: application/json' --header 'Cache-Control: no-cache'
  )
  if [[ -n "$payload" ]]; then
    args+=( --header 'Content-Type: application/json' --data "$payload" )
  fi

  if ! PROD_API_STATUS=$(curl "${args[@]}" "${PROD_N8N_API_BASE_URL%/}${path}"); then
    echo "[ERR] n8n API transport failed: $method $path" >&2
    return 1
  fi
  if [[ "$PROD_API_STATUS" == 200 ]] || [[ "$allow_missing" == true && "$PROD_API_STATUS" == 404 ]]; then
    return 0
  fi
  echo "[ERR] n8n API failed: $method $path (HTTP $PROD_API_STATUS)." >&2
  # Keep the server's rejection reason before cleanup removes the response file.
  # Log only diagnostic fields, redact the API key, and escape control characters.
  local error_detail
  if error_detail=$(PROD_API_REDACT_KEY="$PROD_N8N_API_KEY" jq -er '
    select(type == "object")
    | {code, message, error}
    | with_entries(select(.value != null))
    | if (.error | type) == "object" then
        .error |= {code, message} | .error |= with_entries(select(.value != null))
      else . end
    | with_entries(select((.value | type) == "string" or (.value | type) == "number" or (.value | type) == "object"))
    | select(length > 0)
    | tostring
    | split(env.PROD_API_REDACT_KEY) | join("[REDACTED]")
    | .[0:2000]
  ' "$response_file" 2>/dev/null); then
    printf '[ERR] n8n API response: %s\n' "$error_detail" >&2
  else
    echo '[ERR] API response has no readable JSON error message. Check n8n or reverse-proxy logs.' >&2
  fi
  return 1
}

import_workflow_file_to_prod() (
  local local_file="$1"
  local workflow_id="$2"
  [[ "$workflow_id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo '[ERR] Invalid workflow ID'; exit 1; }
  : "${PROD_N8N_API_BASE_URL:?PROD_N8N_API_BASE_URL is required}"
  : "${PROD_N8N_API_KEY:?PROD_N8N_API_KEY is required}"
  case "$PROD_DEPLOY_TARGET" in
    docker|kubernetes|kubectl) ;;
    *) echo "[ERR] Unsupported PROD_DEPLOY_TARGET: $PROD_DEPLOY_TARGET"; exit 1 ;;
  esac

  local deploy_tmp pod_name='' host_file=''
  deploy_tmp=$(mktemp -d)
  local container_file="/tmp/n8n-deploy-${workflow_id}-${RANDOM}-${RANDOM}.json"
  local response_file="${deploy_tmp}/response.json"
  local staged_file="${deploy_tmp}/workflow.json"
  local deployment_started=false previous_version=''
  cleanup_workflow_deploy() {
    local status=$?
    trap - EXIT
    if [[ "$PROD_DEPLOY_TARGET" == docker && -n "$host_file" ]]; then
      ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
        "rm -f '$host_file'; docker exec '$PROD_CONTAINER' rm -f '$container_file'" >/dev/null 2>&1 || true
    elif [[ -n "$pod_name" ]]; then
      kubectl --kubeconfig="$PROD_KUBECONFIG" exec "$pod_name" -n "$PROD_K8S_NAMESPACE" \
        ${PROD_K8S_CONTAINER:+-c $PROD_K8S_CONTAINER} -- rm -f "$container_file" >/dev/null 2>&1 || true
    fi
    rm -rf "$deploy_tmp"
    if [[ "$status" -ne 0 && "$deployment_started" == true ]]; then
      echo "[ERR] Deployment failed for $workflow_id; it may remain unpublished. Fix the reported error and redeploy. No CLI publish fallback was attempted." >&2
    fi
    exit "$status"
  }
  trap cleanup_workflow_deploy EXIT

  # Import exactly the requested workflow as a fresh draft. DEV publication/history
  # metadata must not select an old PROD version on a repeated deployment.
  jq -e --arg id "$workflow_id" '
    (if type == "array" and length == 1 then .[0] else . end)
    | if type == "object" and .id == $id and (.nodes | type) == "array" then
        .active = false | .activeVersionId = null
        | del(.activeVersion, .versionId, .versionCounter)
      else error("Expected exactly one workflow with the requested ID and a nodes array") end
  ' "$local_file" > "$staged_file"

  echo "    Import workflow to PROD ${PROD_DEPLOY_TARGET}: $workflow_id"
  
  case "$PROD_DEPLOY_TARGET" in
    kubernetes|kubectl)
      # Ambil nama pod n8n menggunakan kubeconfig lokal Jenkins
      pod_name=$(kubectl --kubeconfig="$PROD_KUBECONFIG" get pod -n "$PROD_K8S_NAMESPACE" -l "$PROD_K8S_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      
      [[ -n "$pod_name" ]] || { echo "[ERR] Pod n8n tidak ditemukan dengan selector $PROD_K8S_POD_SELECTOR di namespace $PROD_K8S_NAMESPACE"; exit 1; }
      
      echo "    Copying file directly into pod $pod_name..."
      kubectl --kubeconfig="$PROD_KUBECONFIG" cp "$staged_file" "${PROD_K8S_NAMESPACE}/${pod_name}:${container_file}" ${PROD_K8S_CONTAINER:+-c $PROD_K8S_CONTAINER}
      ;;
      
    docker)
      host_file="$container_file"
      scp "${PROD_SCP_OPTS[@]}" "$staged_file" "$PROD_REMOTE:$host_file"
      ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
        "docker cp '$host_file' '$PROD_CONTAINER:$container_file'"
      ;;
  esac

  # Unpublish through the running server BEFORE the CLI changes database state.
  # Only a lookup 404 means a new workflow; auth/server failures abort the deploy.
  prod_workflow_api GET "/workflows/${workflow_id}" "$response_file" '' true
  if [[ "$PROD_API_STATUS" == 200 ]]; then
    jq -e --arg id "$workflow_id" '.id == $id' "$response_file" >/dev/null
    previous_version=$(jq -er '.versionId | select(type == "string" and length > 0)' "$response_file")
    echo "    Unpublish existing workflow before import: $workflow_id"
    deployment_started=true
    prod_workflow_api POST "/workflows/${workflow_id}/deactivate" "$response_file"
    prod_workflow_api GET "/workflows/${workflow_id}" "$response_file"
    jq -e --arg id "$workflow_id" '
      .id == $id and .active == false and .activeVersionId == null
    ' "$response_file" >/dev/null || { echo '[ERR] Workflow is still published; import aborted'; exit 1; }
  else
    echo "    New workflow; no unpublish required: $workflow_id"
  fi

  deployment_started=true
  case "$PROD_DEPLOY_TARGET" in
    kubernetes|kubectl)
      kubectl --kubeconfig="$PROD_KUBECONFIG" exec "$pod_name" -n "$PROD_K8S_NAMESPACE" ${PROD_K8S_CONTAINER:+-c $PROD_K8S_CONTAINER} -- \
        n8n import:workflow --input "$container_file" --projectId "$PROD_PROJECT_ID"
      ;;
    docker)
      ssh "${PROD_SSH_OPTS[@]}" "$PROD_REMOTE" \
        "docker exec -u 0 '$PROD_CONTAINER' n8n import:workflow --input '$container_file' --projectId '$PROD_PROJECT_ID'"
      ;;
  esac

  # Read the version generated in PROD, never the version exported from DEV.
  prod_workflow_api GET "/workflows/${workflow_id}" "$response_file"
  local version_id payload
  version_id=$(jq -er --arg id "$workflow_id" '
    select(.id == $id) | .versionId | select(type == "string" and length > 0)
  ' "$response_file")
  if [[ "$version_id" == "$previous_version" ]]; then
    echo "[ERR] Import did not create a new PROD version for $workflow_id; publish aborted"
    exit 1
  fi
  payload=$(jq -nc --arg version "$version_id" '{versionId: $version}')
  echo "    Publish imported version via REST API: $workflow_id ($version_id)"
  prod_workflow_api POST "/workflows/${workflow_id}/activate" "$response_file" "$payload"
  prod_workflow_api GET "/workflows/${workflow_id}" "$response_file"
  jq -e --arg id "$workflow_id" --arg version "$version_id" '
    .id == $id and .active == true and .versionId == $version and .activeVersionId == $version
  ' "$response_file" >/dev/null || {
    echo "[ERR] Published version verification failed for $workflow_id (expected $version_id)"
    exit 1
  }
  echo "    [OK] Workflow $workflow_id published; activeVersionId matches imported version $version_id."
)

MAP_FILE="${MAP_DIR}/$(basename "${WF_FILE%.json}").credentials.json"

echo "[0] Validate and apply workflow credential mapping"
validate_and_apply_credential_map_if_needed "$WF_FILE" "$MAP_FILE"

if [[ -n "${SUB_WORKFLOW_IDS_CSV:-}" ]]; then
  IFS=',' read -r -a SUB_WORKFLOW_IDS <<< "$SUB_WORKFLOW_IDS_CSV"

  for sub_id_raw in "${SUB_WORKFLOW_IDS[@]}"; do
    sub_id="$(echo "$sub_id_raw" | xargs)"
    [[ -n "$sub_id" ]] || continue

    sub_file="${WF_DIR}/${sub_id}.json"

    if [[ ! -f "$sub_file" ]]; then
      echo "[WARN] Selected sub-workflow file not found in repo while validating credential mapping: $sub_file"
      continue
    fi

    sub_map_file="${MAP_DIR}/$(basename "${sub_file%.json}").credentials.json"
    validate_and_apply_credential_map_if_needed "$sub_file" "$sub_map_file"
  done
fi

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  echo "[OK] Validation only mode completed."
  exit 0
fi

PROD_PROJECT_ID="$(remote_psql 'select id from project order by "createdAt" asc limit 1;' | tr -d '\r' | xargs)"

[[ -n "$PROD_PROJECT_ID" ]] || {
  echo "[ERR] PROD_PROJECT_ID not found"
  exit 1
}

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

    echo "    Push selected sub-workflow: $sub_id"
    
    # --- PANGGIL FUNGSI INJECT UNTUK SUB-WORKFLOW DI SINI ---
    inject_workflow_settings "$sub_file"    
    import_workflow_file_to_prod "$sub_file" "$sub_id"
    
    # [TAMBAHKAN DI SINI UNTUK SUB-WORKFLOW]
    sync_and_move_to_prod_folder "$sub_id"
  done
fi

echo "    Push main workflow: $WORKFLOW_ID"

# --- PANGGIL FUNGSI INJECT UNTUK MAIN WORKFLOW DI SINI ---
inject_workflow_settings "$WF_FILE"

import_workflow_file_to_prod "$WF_FILE" "$WORKFLOW_ID"

# [TAMBAHKAN DI SINI UNTUK MAIN WORKFLOW]
sync_and_move_to_prod_folder "$WORKFLOW_ID"

echo "[3] Done"

