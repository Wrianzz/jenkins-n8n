class GitWorkflowOps implements Serializable {
  private final def steps

  GitWorkflowOps(def steps) {
    this.steps = steps
  }

  void checkoutRequiredFiles(String repoHttp, String gitCredId) {
    steps.checkout([
      $class: 'GitSCM',
      branches: [[name: '*/master']],
      userRemoteConfigs: [[
        url: repoHttp,
        credentialsId: gitCredId
      ]],
      extensions: [[
        $class: 'SparseCheckoutPaths',
        sparseCheckoutPaths: [
          [path: 'scripts/'],
          [path: 'workflows/'],
          [path: 'jenkins/']
        ]
      ]]
    ])
  }

  void prepareWorkflowBranch(String gitCredId, String workflowId) {
    steps.withCredentials([steps.usernamePassword(
      credentialsId: gitCredId,
      usernameVariable: 'GH_USER',
      passwordVariable: 'GH_PASS'
    )]) {
      steps.sh """
        set -e
        git remote set-url origin \"http://\${GH_USER}:\${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git\"
        git fetch origin master
        git checkout -B \"workflow/${workflowId}\" origin/master
      """
    }
  }

  void commitAndPushWorkflowOnly(String gitCredId, String workflowId, String authorName, String authorEmail) {
    steps.withCredentials([steps.usernamePassword(
      credentialsId: gitCredId,
      usernameVariable: 'GH_USER',
      passwordVariable: 'GH_PASS'
    )]) {
      steps.sh """
        set -e
        set +x

        git status
        git config user.email \"${authorEmail}\"
        git config user.name  \"${authorName}\"

        find . -mindepth 1 -maxdepth 1 ! -name '.git' ! -name 'workflows' -exec rm -rf {} +
        find workflows -maxdepth 1 -type f -name '*.json' ! -name \"${workflowId}.json\" -delete || true

        git add -A .
        if git diff --cached --quiet; then
          echo \"[INFO] No changes to commit for workflows/${workflowId}.json\"
        else
          git commit -m \"export workflow ${workflowId} from dev\"
        fi

        git remote set-url origin \"http://\${GH_USER}:\${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git\"
        if git ls-remote --exit-code --heads origin \"workflow/${workflowId}\" >/dev/null 2>&1; then
          git push --force-with-lease origin HEAD:\"workflow/${workflowId}\"
        else
          git push origin HEAD:\"workflow/${workflowId}\"
        fi
      """
    }
  }

  void promoteWorkflowToMaster(String gitCredId, String workflowId, String authorName, String authorEmail) {
    steps.withCredentials([steps.usernamePassword(
      credentialsId: gitCredId,
      usernameVariable: 'GH_USER',
      passwordVariable: 'GH_PASS'
    )]) {
      steps.sh """
        set -e
        set +x

        git config user.email \"${authorEmail}\"
        git config user.name  \"${authorName}\"
        git remote set-url origin \"http://\${GH_USER}:\${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git\"

        git fetch origin master \"workflow/${workflowId}\"
        git checkout -B master origin/master
        git checkout \"origin/workflow/${workflowId}\" -- \"workflows/${workflowId}.json\"

        if git diff --quiet HEAD -- \"workflows/${workflowId}.json\"; then
          echo \"[INFO] workflows/${workflowId}.json already up to date in master\"
        else
          git add \"workflows/${workflowId}.json\"
          git commit -m \"promote workflow ${workflowId} from workflow branch to master\"
          git push origin HEAD:master
        fi
      """
    }
  }
}

return new GitWorkflowOps(this)
