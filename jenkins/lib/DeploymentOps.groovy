// vars/deployOps.groovy

def exportWorkflowFromDev(String sshCredId, String workflowId, String selectedSubWorkflowIds = '') {
  withCredentials([sshUserPrivateKey(
    credentialsId: sshCredId,
    keyFileVariable: 'SSH_KEY_FILE'
  )]) {
    sh """
      set -e
      chmod +x scripts/export-to-git.sh
      export SSH_KEY_FILE
      scripts/export-to-git.sh "${workflowId}" "${selectedSubWorkflowIds}"
    """
  }
}

def discoverAndSelectSubWorkflows(String workflowId) {
  String workflowFile = "workflows/${workflowId}.json"
  String rawSubWorkflowIds = sh(
    script: """
      set -euo pipefail
      jq -r '
        def wf_objs: if type == "array" then .[] else . end;
        wf_objs
        | .nodes[]?
        | select((.type // "") | test("executeWorkflow"; "i"))
        | (.parameters.workflowId // .parameters.workflow?.id // empty)
        | if type == "string" then . elif type == "object" then (.value // empty) else empty end
      ' '${workflowFile}' | awk 'NF' | sort -u
    """,
    returnStdout: true
  ).trim()

  if (!rawSubWorkflowIds) return ''
  List<String> subWorkflowIds = rawSubWorkflowIds.readLines().collect { it.trim() }.findAll { it }

  List selectionParams = subWorkflowIds.collect { subId ->
    [$class: 'BooleanParameterDefinition', name: "PUSH_SUBWF_${subId}", defaultValue: false, description: "Include sub-workflow ${subId} in repo/prod push"]
  }
  def inputResult = input(id: "subworkflow-selection-${env.BUILD_NUMBER}", message: "Select sub-workflow(s) to include before approval", ok: 'Confirm', parameters: selectionParams)

  List<String> selectedIds = []
  if (inputResult instanceof Boolean) {
    if (inputResult == true && !subWorkflowIds.isEmpty()) selectedIds << subWorkflowIds[0]
  }
  if (inputResult instanceof Map) {
    inputResult.each { key, value ->
      if (key?.toString()?.startsWith('PUSH_SUBWF_') && value?.toString()?.equalsIgnoreCase('true')) {
        selectedIds << key.toString().replaceFirst('^PUSH_SUBWF_', '').trim()
      }
    }
  }
  return selectedIds.unique().join(',')
}

def discoverSubWorkflowIdsFromFile(String workflowId) {
  String workflowFile = "workflows/${workflowId}.json"
  return sh(
    script: """
      set -euo pipefail
      jq -r '
        def wf_objs: if type == "array" then .[] else . end;
        wf_objs
        | .nodes[]?
        | select((.type // "") | test("executeWorkflow"; "i"))
        | (.parameters.workflowId // .parameters.workflow?.id // empty)
        | if type == "string" then . elif type == "object" then (.value // empty) else empty end
      ' '${workflowFile}' | awk 'NF' | sort -u | paste -sd ',' -
    """,
    returnStdout: true
  ).trim()
}

def deployFromRepoToProd(String sshCredId, String workflowId, String selectedSubWorkflowIds = '') {
  String selectedSubWorkflowIdsArg = selectedSubWorkflowIds?.trim() ?: ''

  echo "[DeploymentOps] Selected sub-workflow IDs to push: ${selectedSubWorkflowIdsArg ?: '(none)'}"

  withCredentials([sshUserPrivateKey(
    credentialsId: sshCredId,
    keyFileVariable: 'SSH_KEY_FILE'
  )]) {
    sh """
      set -e
      chmod +x scripts/deploy-from-git.sh
      export SSH_KEY_FILE
      scripts/deploy-from-git.sh "${workflowId}" "${selectedSubWorkflowIdsArg}"
    """
  }
}

def validateWorkflowCredentialsOnly(String gitCredId, String workflowId, String selectedSubWorkflowIds = '') {
  String selectedSubWorkflowIdsArg = selectedSubWorkflowIds?.trim() ?: ''

  withCredentials([
    usernamePassword(
      credentialsId: gitCredId,
      usernameVariable: 'GH_USER',
      passwordVariable: 'GH_PASS'
    )
  ]) {
    sh """
      set -euo pipefail

      VALIDATION_TMP_DIR="\${JENKINS_HOME:-/jenkins_home}/n8n-validate-script-${workflowId}-\${BUILD_NUMBER:-0}"
      
      cleanup() {
        rm -rf "\$VALIDATION_TMP_DIR"
      }
      trap cleanup EXIT

      mkdir -p "\$VALIDATION_TMP_DIR"
      cp scripts/validate-dev-credentials.sh "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh"
      chmod +x "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh"

      git remote set-url origin "http://\$GH_USER:\$GH_PASS@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"
      git fetch origin "+refs/heads/workflow/${workflowId}:refs/remotes/origin/workflow/${workflowId}"
      if git show-ref --verify --quiet "refs/remotes/origin/workflow/${workflowId}"; then
        git checkout -B "workflow/${workflowId}" "origin/workflow/${workflowId}"
        echo "[INFO] Using workflow branch workflow/${workflowId} for validation"
      else
        echo "[ERR] Branch workflow/${workflowId} not found on remote after explicit fetch."
        echo "[ERR] Make sure branch workflow/${workflowId} already exists in remote repository."
        exit 1
      fi

      if [ -n "${selectedSubWorkflowIdsArg}" ]; then
        SUB_IDS_NORMALIZED="\$(echo "${selectedSubWorkflowIdsArg}" | tr ',\\n\\r\\t' '    ')"
        for _sid in \$SUB_IDS_NORMALIZED; do
          _sid_trim="\$(echo "\$_sid" | xargs)"
          [ -n "\$_sid_trim" ] || continue

          if git ls-remote --exit-code --heads origin "workflow/\${_sid_trim}" >/dev/null 2>&1; then
            git fetch origin "workflow/\${_sid_trim}"
            git checkout "origin/workflow/\${_sid_trim}" -- "workflows/\${_sid_trim}.json"
            if git cat-file -e "origin/workflow/\${_sid_trim}:workflows/credential-maps/\${_sid_trim}.credentials.json" 2>/dev/null; then
              git checkout "origin/workflow/\${_sid_trim}" -- "workflows/credential-maps/\${_sid_trim}.credentials.json"
            fi
            echo "[INFO] Loaded sub-workflow file from branch workflow/\${_sid_trim}"
          else
            echo "[WARN] Branch workflow/\${_sid_trim} not found; validating using checked-out files only"
          fi
        done
      fi

      "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh" "${workflowId}" "workflows/${workflowId}.json" "${selectedSubWorkflowIdsArg}"
    """
  }
}
