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
      scripts/deploy-from-git.sh "${workflowId}"
    """
  }
}

def validateWorkflowCredentialsOnly(String sshCredId, String gitCredId, String workflowId) {
  withCredentials([
    sshUserPrivateKey(
      credentialsId: sshCredId,
      keyFileVariable: 'SSH_KEY_FILE'
    ),
    usernamePassword(
      credentialsId: gitCredId,
      usernameVariable: 'GH_USER',
      passwordVariable: 'GH_PASS'
    )
  ]) {
    sh """
      set -euo pipefail

      VALIDATION_TMP_DIR="${JENKINS_HOME:-/jenkins_home}/n8n-validate-script-${workflowId}-${BUILD_NUMBER:-0}"
      cleanup() {
        rm -rf "$VALIDATION_TMP_DIR"
      }
      trap cleanup EXIT

      mkdir -p "$VALIDATION_TMP_DIR"
      cp scripts/validate-dev-credentials.sh "$VALIDATION_TMP_DIR/validate-dev-credentials.sh"
      chmod +x "$VALIDATION_TMP_DIR/validate-dev-credentials.sh"

      git remote set-url origin "http://${GH_USER}:${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"
      git fetch origin master
      if git ls-remote --exit-code --heads origin "workflow/${workflowId}" >/dev/null 2>&1; then
        git fetch origin "workflow/${workflowId}"
        git checkout -B "workflow/${workflowId}" "origin/workflow/${workflowId}"
      else
        echo "[WARN] Branch workflow/${workflowId} not found on remote. Are you sure you already push the Workflow?."
      fi

      export SSH_KEY_FILE
      "$VALIDATION_TMP_DIR/validate-dev-credentials.sh" "${workflowId}"
    """
  }
}
