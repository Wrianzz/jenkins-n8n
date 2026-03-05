class DeploymentOps implements Serializable {
  private final def steps

  DeploymentOps(def steps) {
    this.steps = steps
  }

  void exportWorkflowFromDev(String sshCredId, String workflowId) {
    steps.withCredentials([steps.sshUserPrivateKey(
      credentialsId: sshCredId,
      keyFileVariable: 'SSH_KEY_FILE'
    )]) {
      steps.sh """
        set -e
        chmod +x scripts/export-to-git.sh
        export SSH_KEY_FILE
        scripts/export-to-git.sh \"${workflowId}\"
      """
    }
  }

  void deployFromRepoToProd(String sshCredId, String workflowId) {
    steps.withCredentials([steps.sshUserPrivateKey(
      credentialsId: sshCredId,
      keyFileVariable: 'SSH_KEY_FILE'
    )]) {
      steps.sh """
        set -e
        chmod +x scripts/deploy-from-git.sh scripts/promote-creds.sh
        export SSH_KEY_FILE
        scripts/deploy-from-git.sh \"${workflowId}\"
      """
    }
  }
}

return new DeploymentOps(this)
