/**
 * Sends a standardized email notification for the n8n CI/CD pipeline.
 *
 * @param config A map containing the notification configuration.
 * @param config.MAILMODE (Required) Valid modes: 'APPROVAL_REQUIRED', 'POST_BUILD_REPORT'.
 * @param config.RECIPIENT_EMAIL (Optional) The primary recipient's email address.
 * @param config.RECIPIENT_NAME (Optional) The primary recipient's name for personalization.
 * @param config.EXTRA_DATA (Optional) A map for any additional data.
 * - For APPROVAL_REQUIRED:
 *   [approvalLevel: 1|2, previousApprover: 'username']
 * - For POST_BUILD_REPORT:
 *   [buildResult: 'SUCCESS' | 'FAILURE' | 'ABORTED', firstApprover: '', secondApprover: '']
 */
def call(Map config = [:]) {
    def primaryRecipientEmail = config.RECIPIENT_EMAIL ?: env.authorEmail
    if (!primaryRecipientEmail?.trim() || primaryRecipientEmail.toString().equalsIgnoreCase('null')) {
        echo "WARN: [sendEmailTemplate] Primary recipient is invalid (Null/Empty). Skipping email notification."
        return
    }

    def pipelineUrl = buildBlueOceanRunUrl() ?: 'URL_NOT_AVAILABLE'

    def emailSubject
    def emailBody
    def primaryRecipientName = config.RECIPIENT_NAME ?: env.authorName ?: 'Team'

    def targetEnv = (env.PIPELINE_MODE && env.PIPELINE_MODE.contains('PROD')) ? 'PRODUCTION' : 'REPOSITORY/DEV'

    switch (config.MAILMODE) {
        case 'APPROVAL_REQUIRED':
            def approvalLevel = (config.EXTRA_DATA?.approvalLevel ?: 1) as Integer
            def previousApprover = config.EXTRA_DATA?.previousApprover ?: '-'

            if (approvalLevel == 1) {
                emailSubject = "[APPROVAL REQUIRED] [${targetEnv}] n8n Workflow Deployment - ${env.JOB_NAME} #${env.BUILD_NUMBER}"
                emailBody = """
A deployment of an n8n workflow to the ${targetEnv} environment has been initiated and requires the first approval.

Workflow ID: ${env.WORKFLOW_ID}
Triggered by: ${env.authorName} (${env.authorEmail})
Approval: 1 of 2

Please access the Jenkins pipeline via the link below to approve or reject the deployment.
"""
            } else {
                emailSubject = "[APPROVAL REQUIRED] [${targetEnv}] n8n Workflow Deployment - ${env.JOB_NAME} #${env.BUILD_NUMBER}"
                emailBody = """
The first approval for this n8n workflow deployment has already been granted.

Workflow ID: ${env.WORKFLOW_ID}
Triggered by: ${env.authorName} (${env.authorEmail})
Approval: 2 of 2
First Approver: ${previousApprover}

A second approval from a different approver is now required before the pipeline can proceed.
Please access the Jenkins pipeline via the link below to approve or reject the deployment.
"""
            }
            break

        case 'POST_BUILD_REPORT':
            def buildResult = config.EXTRA_DATA?.buildResult ?: 'UNKNOWN'
            def firstApprover = config.EXTRA_DATA?.firstApprover ?: '-'
            def secondApprover = config.EXTRA_DATA?.secondApprover ?: '-'

            emailSubject = "[${buildResult}] [${targetEnv}] n8n CI/CD Pipeline - ${env.JOB_NAME} #${env.BUILD_NUMBER}"
            emailBody = """
The n8n CI/CD pipeline has completed with the result: ${buildResult}.

Workflow ID: ${env.WORKFLOW_ID}
Pipeline Mode: ${env.PIPELINE_MODE}
First Approver: ${firstApprover}
Second Approver: ${secondApprover}

Please review the pipeline logs via the link below for further details.
"""
            break

        default:
            error("Invalid MAILMODE '${config.MAILMODE}' provided to the mail function.")
            break
    }

    def finalBody = """
Hello,

${emailBody}

Pipeline URL:
${pipelineUrl}

Thank you.

Best regards,
DevSecOps Team
"""

    emailext(
        attachLog: (config.EXTRA_DATA?.buildResult == 'FAILURE'),
        subject: emailSubject,
        body: finalBody,
        to: "${primaryRecipientEmail}"
    )
}

String buildBlueOceanRunUrl() {
    def baseUrl = (env.JENKINS_URL ?: '').trim()
    def fullJobName = (env.JOB_NAME ?: '').trim()
    def buildNumber = (env.BUILD_NUMBER ?: '').trim()
    def leafJobName = fullJobName.tokenize('/').last()

    def encodedFullJobName = java.net.URLEncoder.encode(fullJobName, 'UTF-8').replace('+', '%20')
    def encodedLeafJobName = java.net.URLEncoder.encode(leafJobName, 'UTF-8').replace('+', '%20')

    return "${baseUrl}blue/organizations/jenkins/${encodedFullJobName}/detail/${encodedLeafJobName}/${buildNumber}/pipeline"
}
