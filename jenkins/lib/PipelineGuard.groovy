class PipelineGuard implements Serializable {
  private final def steps

  PipelineGuard(def steps) {
    this.steps = steps
  }

  void requestApproval(String pipelineMode, String workflowId, String submitter) {
    steps.input(
      message: "Mode ${pipelineMode}: yakin lanjut promote 1 file workflow (workflow/${workflowId}) ke master + deploy ke PROD?",
      ok: 'Approve & Continue',
      submitter: submitter
    )
  }
}

return new PipelineGuard(this)
