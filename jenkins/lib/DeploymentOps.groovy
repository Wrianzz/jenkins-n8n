// vars/deployOps.groovy

def exportWorkflowFromDev(String sshCredId, String workflowId) {
  withCredentials([sshUserPrivateKey(
    credentialsId: sshCredId,
    keyFileVariable: 'SSH_KEY_FILE'
  )]) {
    sh """
      set -e
      chmod +x scripts/export-to-git.sh
      export SSH_KEY_FILE
      scripts/export-to-git.sh "${workflowId}"
    """
  }
}

def deployFromRepoToProd(String sshCredId, String workflowId) {
  withCredentials([sshUserPrivateKey(
    credentialsId: sshCredId,
    keyFileVariable: 'SSH_KEY_FILE'
  )]) {
    sh """
      set -e
      chmod +x scripts/deploy-from-git.sh scripts/promote-creds.sh
      export SSH_KEY_FILE
      scripts/deploy-from-git.sh "${workflowId}" "${env.SELECTED_SUBWORKFLOW_IDS ?: ''}"
    """
  }
}

def validateAndSelectSubWorkflowsForProd(String sshCredId, String workflowId) {
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
      ' '${workflowFile}' | awk 'NF' | sort -u
    """,
    returnStdout: true
  ).trim()

  if (!rawSubWorkflowIds) {
    echo "[DeploymentOps] Workflow ${workflowId} does not depend on sub-workflow. Continue as usual."
    return ''
  }

  List<String> subWorkflowIds = rawSubWorkflowIds.readLines().collect { it.trim() }.findAll { it }
  echo "[DeploymentOps] Found sub-workflow reference(s): ${subWorkflowIds.join(', ')}"

  withCredentials([sshUserPrivateKey(credentialsId: sshCredId, keyFileVariable: 'SSH_KEY_FILE')]) {
    for (String subId : subWorkflowIds) {
      String exists = sh(
        script: """
          set -euo pipefail
          PROD_REMOTE="${env.PROD_SSH_USER}@${env.PROD_SSH_HOST}"
          ssh -i "$SSH_KEY_FILE" -p "${env.PROD_SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$PROD_REMOTE" \
            "docker exec '${env.PROD_PG_CONTAINER}' psql -U n8n -d n8n -tA -c \"select count(1) from workflow_entity where id='${subId}';\"" | tr -d '\\r' | xargs
        """,
        returnStdout: true
      ).trim()

      if (exists != '1') {
        error("""[ABORT] Sub-workflow '${subId}' was not found in production instance.
Please contact DevOps team to setup/import the sub-workflow first, then rerun this pipeline.""")
      }
    }
  }

  List selectionParams = subWorkflowIds.collect { subId ->
    booleanParam(name: "PUSH_SUBWF_${subId}", defaultValue: false, description: "Push sub-workflow ${subId} to production")
  }

  Map inputResult = input(
    id: "subworkflow-selection-${env.BUILD_NUMBER}",
    message: "Sub-workflow found for main workflow ${workflowId}. Choose sub-workflow(s) to also push to production (optional).",
    ok: 'Confirm Sub-workflow Selection',
    parameters: selectionParams
  )

  if (!(inputResult instanceof Map)) {
    return ''
  }

  List<String> selectedIds = []
  subWorkflowIds.each { subId ->
    if (inputResult["PUSH_SUBWF_${subId}"] == true) {
      selectedIds << subId
    }
  }

  return selectedIds.join(',')
}

def validateWorkflowCredentialsOnly(String gitCredId, String workflowId) {
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
      cp scripts/validate-dev-credentials.sh "\$VALIDATION_MP_DIR/validate-dev-credentials.sh"
      chmod +x "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh"

      git remote set-url origin "http://${GH_USER}:${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"
      git fetch origin master
      
      if git ls-remote --exit-code --heads origin "workflow/${workflowId}" >/dev/null 2>&1; then
        git fetch origin "workflow/${workflowId}"
        git checkout -B "workflow/${workflowId}" "origin/workflow/${workflowId}"
      else
        echo "[ERR] Branch workflow/${workflowId} not found on remote. Are you sure you already push the Workflow?."
        exit 1T
      fi

      "\$VALIDATION_TMP_DIR/validate-dev-credentials.sh" "${workflowId}" "workflows/${workflowId}.json"
    """
  }
}
