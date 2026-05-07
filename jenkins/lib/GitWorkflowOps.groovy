// vars/gitOps.groovy

def checkoutRequiredFiles(String repoHttp, String gitCredId) {
  checkout([
    $class: 'GitSCM',
    branches: [[name: '*/master']],
    userRemoteConfigs: [[
      url: repoHttp,
      credentialsId: gitCredId
    ]],
    extensions: [[
      $class: 'SparseCheckoutPaths',
      sparseCheckoutPaths: [
        [path: 'scripts'],
        [path: 'workflows'],
        [path: 'jenkins']
      ]
    ]]
  ])
}

def prepareWorkflowBranch(String gitCredId, String workflowId) {
  withCredentials([usernamePassword(
    credentialsId: gitCredId,
    usernameVariable: 'GH_USER',
    passwordVariable: 'GH_PASS'
  )]) {
    sh """
      set -e
      git remote set-url origin "http://\${GH_USER}:\${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"
      git fetch origin master
      git checkout -B "workflow/${workflowId}" origin/master
    """
  }
}

def commitAndPushWorkflowOnly(String gitCredId, String workflowId, String selectedSubWorkflowIds, String authorName, String authorEmail) {
  withCredentials([usernamePassword(
    credentialsId: gitCredId,
    usernameVariable: 'GH_USER',
    passwordVariable: 'GH_PASS'
  )]) {
    sh """
      set -e
      set +x

      git status
      git config user.email "${authorEmail}"
      git config user.name  "${authorName}"

      find . -mindepth 1 -maxdepth 1 ! -name '.git' ! -name 'workflows' -exec rm -rf {} +
      KEEP_FILES="${workflowId}.json"
      if [ -n "${selectedSubWorkflowIds}" ]; then
        IFS=',' read -r -a _subs <<< "${selectedSubWorkflowIds}"
        for _sid in "\${_subs[@]}"; do
          _sid_trim=\"\$(echo \"\$_sid\" | xargs)\"
          [ -n "\$_sid_trim" ] && KEEP_FILES="\${KEEP_FILES},\${_sid_trim}.json"
        done
      fi

      find workflows -maxdepth 1 -type f -name '*.json' | while read -r f; do
        b=\"\$(basename \"$f\")\"
        case ",\$KEEP_FILES," in
          *,\"$b\",*) ;;
          *) rm -f "\$f" ;;
        esac
      done

      git add -A .
      if git diff --cached --quiet; then
        echo "[INFO] No changes to commit for workflows/${workflowId}.json"
      else
        git commit -m "export workflow ${workflowId} from dev"
      fi

      git remote set-url origin "http://\${GH_USER}:\${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"
      if git ls-remote --exit-code --heads origin "workflow/${workflowId}" >/dev/null 2>&1; then
        git push --force-with-lease origin HEAD:refs/heads/workflow/${workflowId}
      else
        git push origin HEAD:refs/heads/workflow/${workflowId}
      fi

      git checkout master
    """
  }
}

def promoteWorkflowToMaster(String gitCredId, String workflowId, String selectedSubWorkflowIds, String authorName, String authorEmail) {
  withCredentials([usernamePassword(
    credentialsId: gitCredId,
    usernameVariable: 'GH_USER',
    passwordVariable: 'GH_PASS'
  )]) {
    sh """
      set -e
      set +x

      git config user.email "${authorEmail}"
      git config user.name  "${authorName}"
      git remote set-url origin "http://\${GH_USER}:\${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"

      git fetch origin master "workflow/${workflowId}"
      git checkout -B master origin/master
      git checkout "origin/workflow/${workflowId}" -- "workflows/${workflowId}.json"
      if [ -n "${selectedSubWorkflowIds}" ]; then
        IFS=',' read -r -a _subs <<< "${selectedSubWorkflowIds}"
        for _sid in "\${_subs[@]}"; do
          _sid_trim=\"\$(echo \"\$_sid\" | xargs)\"
          [ -n "\$_sid_trim" ] && git checkout "origin/workflow/${workflowId}" -- "workflows/\${_sid_trim}.json" || true
        done
      fi

      if git diff --quiet HEAD -- workflows/*.json; then
        echo "[INFO] workflows/${workflowId}.json already up to date in master"
      else
        git add workflows/*.json
        git commit -m "promote workflow ${workflowId} and selected sub-workflows from workflow branch to master"
        git push origin HEAD:master
      fi
    """
  }
}
