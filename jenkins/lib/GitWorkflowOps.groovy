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
  String selectedSubWorkflowIdsArg = selectedSubWorkflowIds?.trim() ?: ''

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
      git remote set-url origin "http://\${GH_USER}:\${GH_PASS}@atlassian.satnusa.com:7990/scm/dvo/n8n-cicd-workflows.git"

      EXPORT_TMP_DIR="\$(mktemp -d)"
      trap 'rm -rf "\$EXPORT_TMP_DIR"' EXIT
      cp "workflows/${workflowId}.json" "\$EXPORT_TMP_DIR/${workflowId}.json"

      if [ -n "${selectedSubWorkflowIdsArg}" ]; then
        SUB_IDS_NORMALIZED="\$(echo "${selectedSubWorkflowIdsArg}" | tr ',\\n\\r\\t' '    ')"
        for _sid in \$SUB_IDS_NORMALIZED; do
          _sid_trim=\"\$(echo \"\$_sid\" | xargs)\"
          [ -n "\$_sid_trim" ] || continue
          [ -f "workflows/\${_sid_trim}.json" ] && cp "workflows/\${_sid_trim}.json" "\$EXPORT_TMP_DIR/\${_sid_trim}.json" || true
        done
      fi

      git fetch origin master

      git checkout -B "workflow/${workflowId}" origin/master
      cp "\$EXPORT_TMP_DIR/${workflowId}.json" "workflows/${workflowId}.json"
      git add "workflows/${workflowId}.json"
      if git diff --cached --quiet; then
        echo "[INFO] No changes to commit for workflows/${workflowId}.json"
      else
        git commit -m "export workflow ${workflowId} from dev"
      fi
      if git ls-remote --exit-code --heads origin "workflow/${workflowId}" >/dev/null 2>&1; then
        git push --force-with-lease origin HEAD:refs/heads/workflow/${workflowId}
      else
        git push origin HEAD:refs/heads/workflow/${workflowId}
      fi

      if [ -n "${selectedSubWorkflowIdsArg}" ]; then
        SUB_IDS_NORMALIZED="\$(echo "${selectedSubWorkflowIdsArg}" | tr ',\\n\\r\\t' '    ')"
        for _sid in \$SUB_IDS_NORMALIZED; do
          _sid_trim=\"\$(echo \"\$_sid\" | xargs)\"
          [ -n "\$_sid_trim" ] || continue
          [ -f "\$EXPORT_TMP_DIR/\${_sid_trim}.json" ] || continue

          git checkout -B "workflow/\${_sid_trim}" origin/master
          cp "\$EXPORT_TMP_DIR/\${_sid_trim}.json" "workflows/\${_sid_trim}.json"
          git add "workflows/\${_sid_trim}.json"
          if git diff --cached --quiet; then
            echo "[INFO] No changes to commit for workflows/\${_sid_trim}.json"
          else
            git commit -m "export sub-workflow \${_sid_trim} from dev"
          fi

          if git ls-remote --exit-code --heads origin "workflow/\${_sid_trim}" >/dev/null 2>&1; then
            git push --force-with-lease origin HEAD:refs/heads/workflow/\${_sid_trim}
          else
            git push origin HEAD:refs/heads/workflow/\${_sid_trim}
          fi
        done
      fi

      git checkout master
    """
  }
}

def promoteWorkflowToMaster(String gitCredId, String workflowId, String selectedSubWorkflowIds, String authorName, String authorEmail) {
  String selectedSubWorkflowIdsArg = selectedSubWorkflowIds?.trim() ?: ''

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
      if [ -n "${selectedSubWorkflowIdsArg}" ]; then
        SUB_IDS_NORMALIZED="\$(echo "${selectedSubWorkflowIdsArg}" | tr ',\\n\\r\\t' '    ')"
        for _sid in \$SUB_IDS_NORMALIZED; do
          _sid_trim=\"\$(echo \"\$_sid\" | xargs)\"
          [ -n "\$_sid_trim" ] || continue
          if git ls-remote --exit-code --heads origin "workflow/\${_sid_trim}" >/dev/null 2>&1; then
            git fetch origin "workflow/\${_sid_trim}"
            git checkout "origin/workflow/\${_sid_trim}" -- "workflows/\${_sid_trim}.json"
          fi
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
