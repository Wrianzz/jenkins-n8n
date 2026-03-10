def requestTwoApprovals(String pipelineMode, String workflowId, String submitterCsv, String submitterEmailCsv = '') {
  List<String> approvers = parseCsv(submitterCsv).unique()
  List<String> approverEmails = parseCsv(submitterEmailCsv)

  if (approvers.size() < 2) {
    error("[PipelineGuard] There must be at least 2 unique approvers.")
  }

  if (!approverEmails.isEmpty() && approverEmails.size() != approvers.size()) {
    error("[PipelineGuard] APPROVER and APPROVER_EMAIL must be the same, and their order must be aligned.")
  }

  Map<String, String> approverEmailMap = [:]
  for (int i = 0; i < approvers.size(); i++) {
    approverEmailMap[approvers[i]] = (i < approverEmails.size()) ? approverEmails[i] : ''
  }

  // =========================
  // APPROVAL LEVEL 1
  // =========================
  sendEmailTemplate(
    MAILMODE: 'APPROVAL_REQUIRED',
    RECIPIENT_EMAIL: joinCsv(approverEmails),
    RECIPIENT_NAME: approvers.join(', '),
    EXTRA_DATA: [
      approvalLevel: 1
    ]
  )

  def firstApprovalRaw = input(
    id: "approval-l1-${env.BUILD_NUMBER}",
    message: "Mode ${pipelineMode}: Approval level 1 required",
    ok: 'Approve Level 1',
    submitter: approvers.join(','),
    submitterParameter: 'FIRST_APPROVER'
  )

  String firstApprover = extractApprover(firstApprovalRaw, 'FIRST_APPROVER')
  if (!firstApprover) {
    error("[PipelineGuard] Failed to read the first approver from the input step.")
  }

  echo "[PipelineGuard] Approval level 1 granted by: ${firstApprover}"

  // =========================
  // APPROVAL LEVEL 2
  // =========================
  List<String> remainingApprovers = approvers.findAll { it != firstApprover }
  if (remainingApprovers.isEmpty()) {
    error("[PipelineGuard] There are no remaining approvers for approval level 2.")
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

  while (!secondApprover) {
    secondApprovalAttempt++

    if (secondApprovalAttempt > maxSecondApprovalAttempts) {
      error("[PipelineGuard] Second approval failed after ${maxSecondApprovalAttempts} invalid attempts.")
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

    // Safety net:
    // admin Jenkins can still respond to input step,
    // so we validate again to ensure approver 2 != approver 1
    if (candidateApprover == firstApprover) {
      echo "[PipelineGuard] ${candidateApprover} already approved level 1, so they cannot approve level 2. Waiting for a different approver..."
      continue
    }

    secondApprover = candidateApprover
  }

  echo "[PipelineGuard] Approval level 2 granted by: ${secondApprover}"

  return [
    firstApprover : firstApprover,
    secondApprover: secondApprover
  ]
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
