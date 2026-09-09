def requestTwoApprovals(String pipelineMode, String workflowId, String submitterCsv, String submitterEmailCsv = '') {
  List<String> approvers = parseCsv(submitterCsv).unique()
  List<String> approverEmails = parseCsv(submitterEmailCsv)

  if (approvers.size() < 2) {
    currentBuild.result = 'ABORTED'
    error("[PipelineGuard][HUMAN_ERROR] There must be at least 2 unique approvers.")
  }

  if (!approverEmails.isEmpty() && approverEmails.size() != approvers.size()) {
    currentBuild.result = 'ABORTED'
    error("[PipelineGuard][HUMAN_ERROR] APPROVER and APPROVER_EMAIL must be the same, and their order must be aligned.")
  }

  Map<String, String> approverEmailMap = [:]
  for (int i = 0; i < approvers.size(); i++) {
    approverEmailMap[approvers[i]] = (i < approverEmails.size()) ? approverEmails[i] : ''
  }

  try {
    sendEmailTemplate(
      MAILMODE: 'APPROVAL_REQUIRED',
      RECIPIENT_EMAIL: joinCsv(approverEmails),
      RECIPIENT_NAME: approvers.join(', '),
      EXTRA_DATA: [approvalLevel: 1]
    )

    def firstApprovalRaw
    timeout(time: 1, unit: 'HOURS') {
      firstApprovalRaw = input(
        id: "approval-l1-${env.BUILD_NUMBER}",
        message: "Mode ${pipelineMode}: Approval level 1 required",
        ok: 'Approve Level 1',
        submitter: approvers.join(','),
        submitterParameter: 'FIRST_APPROVER'
      )
    }

    String firstApprover = extractApprover(firstApprovalRaw, 'FIRST_APPROVER')
    if (!firstApprover) {
      currentBuild.result = 'ABORTED'
      error("[PipelineGuard][HUMAN_ERROR] Failed to read the first approver from the input step.")
    }

    echo "[PipelineGuard] Approval level 1 granted by: ${firstApprover}"

    List<String> remainingApprovers = approvers.findAll { it != firstApprover }
    if (remainingApprovers.isEmpty()) {
      currentBuild.result = 'ABORTED'
      error("[PipelineGuard][HUMAN_ERROR] There are no remaining approvers for approval level 2.")
    }

    List<String> remainingEmails = []
    for (String approver : remainingApprovers) {
      String email = approverEmailMap[approver]
      if (email?.trim()) {
        remainingEmails << email.trim()
      }
    }

    sendEmailTemplate(
      MAILMODE: 'APPROVAL_REQUIRED',
      RECIPIENT_EMAIL: joinCsv(remainingEmails),
      RECIPIENT_NAME: remainingApprovers.join(', '),
      EXTRA_DATA: [
        approvalLevel: 2,
        previousApprover: firstApprover
      ]
    )

    String secondApprover = ''
    int secondApprovalAttempt = 0
    int maxSecondApprovalAttempts = 10

    timeout(time: 1, unit: 'HOURS') {
      while (!secondApprover) {
        secondApprovalAttempt++

        if (secondApprovalAttempt > maxSecondApprovalAttempts) {
          currentBuild.result = 'ABORTED'
          error("[PipelineGuard][HUMAN_ERROR] Second approval failed after ${maxSecondApprovalAttempts} invalid attempts.")
        }

        def secondApprovalRaw = input(
          id: "approval-l2-${env.BUILD_NUMBER}-${secondApprovalAttempt}",
          message: """Mode ${pipelineMode}: approval level 2 required.
Approval level 1 granted by ${firstApprover}.
Second approver must be different from the first approver.""",
          ok: 'Approve Level 2',
          submitter: remainingApprovers.join(','),
          submitterParameter: 'SECOND_APPROVER'
        )

        String candidateApprover = extractApprover(secondApprovalRaw, 'SECOND_APPROVER')
        if (!candidateApprover) {
          echo "[PipelineGuard] Failed to read the second approver. Waiting for another approval input..."
          continue
        }

        if (candidateApprover == firstApprover) {
          echo "[PipelineGuard] ${candidateApprover} already approved level 1, so they cannot approve level 2. Waiting for a different approver..."
          continue
        }

        secondApprover = candidateApprover
      }
    }

    echo "[PipelineGuard] Approval level 2 granted by: ${secondApprover}"

    return [
      firstApprover : firstApprover,
      secondApprover: secondApprover
    ]

  } catch (org.jenkinsci.plugins.workflow.steps.FlowInterruptedException e) {
    echo "[PipelineGuard] Pipeline dibatalkan: Approval melewati batas waktu 1 jam atau ditolak secara manual."
    currentBuild.result = 'ABORTED'
    error("Approval process aborted due to timeout or rejection.")
  }
}

private List<String> parseCsv(String raw) {
  if (!raw?.trim()) {
    return []
  }
  return raw
    .split(/\s*,\s*/)
    .collect { it.trim() }
    .findAll { it }
}

private String joinCsv(List<String> items) {
  return (items ?: [])
    .collect { it?.trim() }
    .findAll { it }
    .join(', ')
}

private String extractApprover(def inputResult, String key) {
  if (inputResult == null) {
    return ''
  }

  if (inputResult instanceof Map) {
    return (inputResult[key] ?: '').toString().trim()
  }

  return inputResult.toString().trim()
}