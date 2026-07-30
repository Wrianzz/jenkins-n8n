// vars/DeploymentOps.groovy

def exportWorkflowFromDev(String sshCredId, String workflowId, String selectedSubWorkflowIds = '') {
  withCredentials([
    sshUserPrivateKey(credentialsId: sshCredId, keyFileVariable: 'SSH_KEY_FILE'),
    string(credentialsId: env.DEV_N8N_API_KEY_CRED_ID, variable: 'DEV_N8N_API_KEY')
  ]) {
    sh """
      set -euo pipefail

      chmod +x scripts/export-to-git.sh
      export SSH_KEY_FILE
      
      # Lempar ke environment variable bash
      export DEV_N8N_API_BASE_URL="${env.DEV_N8N_API_BASE_URL}"
      export DEV_N8N_API_KEY="\${DEV_N8N_API_KEY}"

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
  String mainWorkflowFile = "workflows/${workflowId}.json"
  
  if (!fileExists(mainWorkflowFile)) {
    echo "[WARN] Main workflow file not found: ${mainWorkflowFile}"
    return ''
  }

  // 1. Ekstrak sub-workflow HANYA dari level pertama (Main Workflow)
  String rawInitial = sh(
    script: "jq -r '${subWorkflowDiscoveryJq()}' '${mainWorkflowFile}' | awk 'NF' | sort -u",
    returnStdout: true
  ).trim()
  
  if (!rawInitial) {
    echo "[DeploymentOps] No valid sub-workflow ID found in ${mainWorkflowFile}"
    return ''
  }

  List<String> subWorkflowIds = rawInitial
    .readLines()
    .collect { it.trim() }
    .findAll { it }
    .unique()

  if (subWorkflowIds.isEmpty()) {
    return ''
  }

  Map<String, String> discoveredSubWorkflows = [:]

  // 2. Iterasi 1 layer: Paksa export dari DEV untuk tiap sub-workflow agar selalu dapat versi terbaru
  for (String subId : subWorkflowIds) {
    String currentFile = "workflows/${subId}.json"

    // [PENTING] Selalu tarik versi terbaru dari DEV
    echo "[INFO] Discovery: Exporting latest sub-workflow ${subId} from DEV..."
    exportWorkflowFromDev(sshCredId, subId)

    if (fileExists(currentFile)) {
      // Ambil nama workflow menggunakan jq (support array dan object)
      String wfName = sh(
        script: "jq -r '(if type == \"array\" then .[0] else . end) | .name // \"Unknown Workflow\"' '${currentFile}'",
        returnStdout: true
      ).trim()
      discoveredSubWorkflows[subId] = wfName
    } else {
      echo "[WARN] Failed to export or read ${subId} from DEV. Using ID as name fallback."
      discoveredSubWorkflows[subId] = "Unknown Workflow"
    }
  }

  // 3. Tampilkan UI Jenkins Parameter menggunakan Nama Workflow
  List selectionParams = discoveredSubWorkflows.collect { subId, subName ->
    [
      $class: 'BooleanParameterDefinition',
      name: "PUSH_SUBWF_${subId}",
      defaultValue: false,
      description: "Include: ${subName} (ID: ${subId})"
    ]
  }

  def inputResult = input(
    id: "subworkflow-selection-${env.BUILD_NUMBER}",
    message: "Select direct sub-workflow(s) to include",
    ok: 'Confirm',
    parameters: selectionParams
  )

  List<String> selectedIds = []

  if (inputResult instanceof Boolean) {
    if (inputResult == true && !discoveredSubWorkflows.isEmpty()) {
      selectedIds << discoveredSubWorkflows.keySet().toList().first()
    }
  } else if (inputResult instanceof Map) {
    inputResult.each { key, value ->
      if (key?.toString()?.startsWith('PUSH_SUBWF_') && value?.toString()?.equalsIgnoreCase('true')) {
        selectedIds << key.toString().replaceFirst('^PUSH_SUBWF_', '').trim()
      }
    }
  }

  selectedIds = selectedIds
    .collect { it.trim() }
    .findAll { it ==~ /^[A-Za-z0-9_-]{10,}$/ }
    .unique()

  return selectedIds.join(',')
}

def discoverSubWorkflowIdsFromFile(String workflowId) {
  String workflowFile = "workflows/${workflowId}.json"

  return sh(
    script: """
      set -euo pipefail

      if [ ! -f '${workflowFile}' ]; then
        echo "[WARN] Workflow file not found while discovering sub-workflows: ${workflowFile}" >&2
        exit 0
      fi

      jq -r '${subWorkflowDiscoveryJq()}' '${workflowFile}' | awk 'NF' | sort -u | paste -sd ',' -
    """,
    returnStdout: true
  ).trim()
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

  // Tambahkan string credential injection di sini
  withCredentials([
    sshUserPrivateKey(credentialsId: sshCredId, keyFileVariable: 'SSH_KEY_FILE'),
    string(credentialsId: env.PROD_N8N_API_KEY_CRED_ID, variable: 'PROD_N8N_API_KEY')
  ]) {
    sh """
      set -euo pipefail

      chmod +x scripts/deploy-from-git.sh scripts/promote-creds.sh
      
      # Export variabelnya agar terbaca oleh curl di dalam bash script
      export SSH_KEY_FILE
      export PROD_N8N_API_KEY

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