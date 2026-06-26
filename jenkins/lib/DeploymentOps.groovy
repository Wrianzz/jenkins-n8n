// vars/DeploymentOps.groovy

def exportWorkflowFromDev(String sshCredId, String workflowId, String selectedSubWorkflowIds = '') {
  withCredentials([sshUserPrivateKey(
    credentialsId: sshCredId,
    keyFileVariable: 'SSH_KEY_FILE'
  )]) {
    sh """
      set -euo pipefail

      chmod +x scripts/export-to-git.sh
      export SSH_KEY_FILE

      scripts/export-to-git.sh "${workflowId}" "${selectedSubWorkflowIds}"
    """
  }
}

def subWorkflowDiscoveryJq() {
  return '''
    def wf_objs:
      if type == "array" then .[] else . end;

    def trim:
      tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");

    def valid_workflow_id:
      test("^[A-Za-z0-9_-]{10,}$")
      and (. != "branch")
      and (. != "master")
      and (. != "dev")
      and (. != "prod")
      and (. != "production");

    def unwrap_workflow_ref:
      if type == "string" then
        .
      elif type == "object" then
        (.value // .id // empty)
      else
        empty
      end;

    wf_objs
    | .nodes[]?
    | select((.type // "") | test("executeWorkflow"; "i"))
    | [
        (.parameters.workflowId? | unwrap_workflow_ref),
        (.parameters.workflow? | unwrap_workflow_ref),
        (.parameters.workflow?.id? // empty),
        (.parameters.workflow?.value? // empty)
      ][]
    | select(type == "string")
    | trim
    | select(length > 0)
    | select(valid_workflow_id)
  '''
}

def discoverAndSelectSubWorkflows(String sshCredId, String workflowId) {
  List<String> subWorkflowIds = discoverRecursiveSubWorkflowIdsFromFiles(workflowId)

  Set<String> exportedIds = [] as Set
  while (true) {
    List<String> missingIds = subWorkflowIds.findAll { subId ->
      subId && !exportedIds.contains(subId) && !fileExists("workflows/${subId}.json")
    }

    if (missingIds.isEmpty()) {
      break
    }

    missingIds.each { subId ->
      echo "[DeploymentOps] Export nested sub-workflow candidate from DEV for recursive discovery: ${subId}"
      exportWorkflowFromDev(sshCredId, subId)
      exportedIds << subId
    }

    List<String> refreshedIds = discoverRecursiveSubWorkflowIdsFromFiles(workflowId)
    if (refreshedIds == subWorkflowIds) {
      break
    }
    subWorkflowIds = refreshedIds
  }

  if (subWorkflowIds.isEmpty()) {
    echo "[DeploymentOps] No valid sub-workflow ID found in workflows/${workflowId}.json or nested sub-workflows"
    return ''
  }

  List selectionParams = []
  subWorkflowIds.eachWithIndex { subId, index ->
    String workflowName = workflowDisplayName(subId)
    selectionParams << [
      $class: 'BooleanParameterDefinition',
      name: "PUSH_SUBWF_${index}",
      defaultValue: false,
      description: "Include sub-workflow ${workflowName} (${subId}) in repo/prod push"
    ]
  }

  def inputResult = input(
    id: "subworkflow-selection-${env.BUILD_NUMBER}",
    message: "Select sub-workflow(s) to include before approval",
    ok: 'Confirm',
    parameters: selectionParams
  )

  List<String> selectedIds = []

  if (inputResult instanceof Boolean) {
    if (inputResult == true && !subWorkflowIds.isEmpty()) {
      selectedIds << subWorkflowIds[0]
    }
  }

  if (inputResult instanceof Map) {
    inputResult.each { key, value ->
      if (key?.toString()?.startsWith('PUSH_SUBWF_') && value?.toString()?.equalsIgnoreCase('true')) {
        String indexText = key.toString().replaceFirst('^PUSH_SUBWF_', '').trim()
        if (indexText ==~ /^[0-9]+$/) {
          Integer selectedIndex = indexText as Integer
          if (selectedIndex >= 0 && selectedIndex < subWorkflowIds.size()) {
            selectedIds << subWorkflowIds[selectedIndex]
          }
        }
      }
    }
  }

  selectedIds = selectedIds
    .collect { it.trim() }
    .findAll { it ==~ /^[A-Za-z0-9_-]{10,}$/ }
    .unique()

  return selectedIds.join(',')
}


def discoverRecursiveSubWorkflowIdsFromFiles(String workflowId) {
  String workflowFile = "workflows/${workflowId}.json"

  String rawSubWorkflowIds = sh(
    script: """
      set -euo pipefail

      if [ ! -f '${workflowFile}' ]; then
        echo "[WARN] Workflow file not found while discovering sub-workflows: ${workflowFile}" >&2
        exit 0
      fi

      tmp_seen="\$(mktemp)"
      tmp_queue="\$(mktemp)"
      tmp_next="\$(mktemp)"
      trap 'rm -f "\$tmp_seen" "\$tmp_queue" "\$tmp_next"' EXIT

      jq -r '${subWorkflowDiscoveryJq()}' '${workflowFile}' | awk 'NF' | sort -u > "\$tmp_queue"

      while [ -s "\$tmp_queue" ]; do
        : > "\$tmp_next"

        while IFS= read -r sub_id; do
          [ -n "\$sub_id" ] || continue
          if grep -Fxq "\$sub_id" "\$tmp_seen"; then
            continue
          fi

          echo "\$sub_id" >> "\$tmp_seen"

          if [ -f "workflows/\${sub_id}.json" ]; then
            jq -r '${subWorkflowDiscoveryJq()}' "workflows/\${sub_id}.json" | awk 'NF' >> "\$tmp_next"
          else
            echo "[INFO] Sub-workflow file not available yet for deeper discovery: workflows/\${sub_id}.json" >&2
          fi
        done < "\$tmp_queue"

        if [ -s "\$tmp_next" ]; then
          sort -u "\$tmp_next" > "\$tmp_queue"
        else
          : > "\$tmp_queue"
        fi
      done

      sort -u "\$tmp_seen"
    """,
    returnStdout: true
  ).trim()

  if (!rawSubWorkflowIds) {
    return []
  }

  return rawSubWorkflowIds
    .readLines()
    .collect { it.trim() }
    .findAll { it && it != workflowId && (it ==~ /^[A-Za-z0-9_-]{10,}$/) }
    .unique()
}

def workflowDisplayName(String workflowId) {
  String workflowFile = "workflows/${workflowId}.json"
  if (!fileExists(workflowFile)) {
    return workflowId
  }

  String displayName = sh(
    script: """
      set -euo pipefail
      jq -r 'if type == "array" then (.[0].name // empty) else (.name // empty) end' '${workflowFile}' | head -n 1
    """,
    returnStdout: true
  ).trim()

  return displayName ?: workflowId
}

def discoverSubWorkflowIdsFromFile(String workflowId) {
  return discoverRecursiveSubWorkflowIdsFromFiles(workflowId).join(',')
}

def discoverSubWorkflowIdsFromRemoteWorkflowBranch(String gitCredId, String workflowId) {
  withCredentials([
    usernamePassword(
      credentialsId: gitCredId,
      usernameVariable: 'GH_USER',
      passwordVariable: 'GH_PASS'
    )
  ]) {
    return sh(
      script: """
        set -euo pipefail

        git remote set-url origin "http://\$GH_USER:\$GH_PASS@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"

        git fetch origin master >&2

        if git ls-remote --exit-code --heads origin "workflow/${workflowId}" >/dev/null 2>&1; then
          git fetch origin "workflow/${workflowId}" >&2
          git checkout -B "workflow/${workflowId}" "origin/workflow/${workflowId}" >&2
          echo "[INFO] Checked out workflow branch for discovery: workflow/${workflowId}" >&2
        else
          echo "[ERR] Branch workflow/${workflowId} not found on remote. Are you sure workflow already pushed?" >&2
          exit 1
        fi

        if [ ! -f "workflows/${workflowId}.json" ]; then
          echo "[ERR] Workflow file not found after checkout: workflows/${workflowId}.json" >&2
          exit 1
        fi

        jq -r '${subWorkflowDiscoveryJq()}' "workflows/${workflowId}.json" | awk 'NF' | sort -u | paste -sd ',' -
      """,
      returnStdout: true
    ).trim()
  }
}

def normalizeAndFilterSubWorkflowIds(String selectedSubWorkflowIds = '') {
  if (!selectedSubWorkflowIds?.trim()) {
    return ''
  }

  List<String> ids = selectedSubWorkflowIds
    .split(',')
    .collect { it.trim() }
    .findAll { it }
    .findAll { subId ->
      !(subId in ['branch', 'master', 'dev', 'prod', 'production']) &&
      (subId ==~ /^[A-Za-z0-9_-]{10,}$/)
    }
    .unique()

  return ids.join(',')
}

def deployFromRepoToProd(String sshCredId, String workflowId, String selectedSubWorkflowIds = '') {
  String selectedSubWorkflowIdsArg = normalizeAndFilterSubWorkflowIds(selectedSubWorkflowIds)

  echo "[DeploymentOps] Selected sub-workflow IDs to push: ${selectedSubWorkflowIdsArg ?: '(none)'}"

  withCredentials([sshUserPrivateKey(
    credentialsId: sshCredId,
    keyFileVariable: 'SSH_KEY_FILE'
  )]) {
    sh """
      set -euo pipefail

      chmod +x scripts/deploy-from-git.sh scripts/promote-creds.sh
      export SSH_KEY_FILE

      scripts/deploy-from-git.sh "${workflowId}" "${selectedSubWorkflowIdsArg}"
    """
  }
}

def validateWorkflowCredentialsOnly(String gitCredId, String workflowId, String selectedSubWorkflowIds = '') {
  String selectedSubWorkflowIdsArg = normalizeAndFilterSubWorkflowIds(selectedSubWorkflowIds)

  withCredentials([
    usernamePassword(
      credentialsId: gitCredId,
      usernameVariable: 'GH_USER',
      passwordVariable: 'GH_PASS'
    )
  ]) {
    sh """
      set -eu

      VALIDATION_TMP_DIR="\${JENKINS_HOME:-/jenkins_home}/n8n-validate-script-${workflowId}-\${BUILD_NUMBER:-0}"

      cleanup() {
        rm -rf "\$VALIDATION_TMP_DIR"
      }
      trap cleanup EXIT

      mkdir -p "\$VALIDATION_TMP_DIR"

      git remote set-url origin "http://\$GH_USER:\$GH_PASS@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"
      git fetch origin master

      echo "[INFO] Load validation script from origin/master"
      git show "origin/master:scripts/validate-dev-credentials.sh" > "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh"
      chmod +x "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh"

      echo "[DEBUG] Validate script source: origin/master:scripts/validate-dev-credentials.sh"
      echo "[DEBUG] Check master validate script has workflow_has_credentials:"
      grep -n "workflow_has_credentials" "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh" || {
        echo "[ERR] validate-dev-credentials.sh from origin/master is still OLD. workflow_has_credentials not found."
        exit 1
      }

      if git ls-remote --exit-code --heads origin "workflow/${workflowId}" >/dev/null 2>&1; then
        git fetch origin "workflow/${workflowId}"
        git checkout -B "workflow/${workflowId}" "origin/workflow/${workflowId}"
        echo "[INFO] Checked out main workflow branch: workflow/${workflowId}"
      else
        echo "[ERR] Branch workflow/${workflowId} not found on remote. Are you sure you already pushed the workflow?"
        exit 1
      fi

      if [ ! -f "workflows/${workflowId}.json" ]; then
        echo "[ERR] Workflow file not found after checkout: workflows/${workflowId}.json"
        exit 1
      fi

      SELECTED_SUBWORKFLOW_IDS_ARG="${selectedSubWorkflowIdsArg}"

      if [ -z "\$SELECTED_SUBWORKFLOW_IDS_ARG" ]; then
        SELECTED_SUBWORKFLOW_IDS_ARG="\$(jq -r '${subWorkflowDiscoveryJq()}' "workflows/${workflowId}.json" | awk 'NF' | sort -u | paste -sd ',' -)"
        echo "[INFO] Auto-discovered sub-workflow IDs after checkout: \${SELECTED_SUBWORKFLOW_IDS_ARG:-'(none)'}"
      else
        echo "[INFO] Sub-workflow IDs from argument: \$SELECTED_SUBWORKFLOW_IDS_ARG"
      fi

      VALID_SUB_WORKFLOW_IDS_ARG=""

      if [ -n "\$SELECTED_SUBWORKFLOW_IDS_ARG" ]; then
        SUB_IDS_NORMALIZED="\$(echo "\$SELECTED_SUBWORKFLOW_IDS_ARG" | tr ',\\n\\r\\t' '    ')"

        for _sid in \$SUB_IDS_NORMALIZED; do
          _sid_trim="\$(echo "\$_sid" | xargs)"
          [ -n "\$_sid_trim" ] || continue

          case "\$_sid_trim" in
            branch|master|dev|prod|production)
              echo "[WARN] Skip invalid sub-workflow id value: \$_sid_trim"
              continue
              ;;
          esac

          if ! echo "\$_sid_trim" | grep -Eq '^[A-Za-z0-9_-]{10,}\$'; then
            echo "[WARN] Skip invalid sub-workflow id format: \$_sid_trim"
            continue
          fi

          if git ls-remote --exit-code --heads origin "workflow/\${_sid_trim}" >/dev/null 2>&1; then
            git fetch origin "workflow/\${_sid_trim}"

            git checkout "origin/workflow/\${_sid_trim}" -- "workflows/\${_sid_trim}.json"

            if git cat-file -e "origin/workflow/\${_sid_trim}:workflows/credential-maps/\${_sid_trim}.credentials.json" 2>/dev/null; then
              git checkout "origin/workflow/\${_sid_trim}" -- "workflows/credential-maps/\${_sid_trim}.credentials.json"
            else
              echo "[INFO] Credential map file not found in branch workflow/\${_sid_trim}. It will be required only if workflow has credentials."
            fi

            if [ -z "\$VALID_SUB_WORKFLOW_IDS_ARG" ]; then
              VALID_SUB_WORKFLOW_IDS_ARG="\$_sid_trim"
            else
              VALID_SUB_WORKFLOW_IDS_ARG="\$VALID_SUB_WORKFLOW_IDS_ARG,\$_sid_trim"
            fi

            echo "[INFO] Loaded sub-workflow file from branch workflow/\${_sid_trim}"
          elif [ -f "workflows/\${_sid_trim}.json" ]; then
            if [ -z "\$VALID_SUB_WORKFLOW_IDS_ARG" ]; then
              VALID_SUB_WORKFLOW_IDS_ARG="\$_sid_trim"
            else
              VALID_SUB_WORKFLOW_IDS_ARG="\$VALID_SUB_WORKFLOW_IDS_ARG,\$_sid_trim"
            fi

            echo "[WARN] Branch workflow/\${_sid_trim} not found; using checked-out file: workflows/\${_sid_trim}.json"
          else
            echo "[WARN] Skip sub-workflow because branch/file not found: \$_sid_trim"
          fi
        done
      fi

      echo "[INFO] Valid sub-workflow IDs for validation: \${VALID_SUB_WORKFLOW_IDS_ARG:-'(none)'}"

      "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh" "${workflowId}" "workflows/${workflowId}.json" "\$VALID_SUB_WORKFLOW_IDS_ARG"
    """
  }
}