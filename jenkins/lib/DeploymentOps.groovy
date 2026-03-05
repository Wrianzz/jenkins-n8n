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
