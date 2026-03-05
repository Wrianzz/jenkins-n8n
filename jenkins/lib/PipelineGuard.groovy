def requestApproval(String pipelineMode, String workflowId, String submitter) {
  input(
    message: "Mode ${pipelineMode}: yakin lanjut promote 1 file workflow (workflow/${workflowId}) ke master + deploy ke PROD?",
    ok: 'Approve & Continue',
    submitter: submitter
  )
}
