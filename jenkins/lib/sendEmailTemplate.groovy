/**
 * Sends a standardized email notification for the n8n CI/CD pipeline.
 *
 * @param config A map containing the notification configuration.
 * @param config.MAILMODE (Required) Valid modes: 'APPROVAL_REQUIRED', 'POST_BUILD_REPORT'.
 * @param config.RECIPIENT_EMAIL (Optional) The primary recipient's email address.
 * @param config.RECIPIENT_NAME (Optional) The primary recipient's name for personalization.
 * @param config.EXTRA_DATA (Optional) A map for any additional data.
 * - For POST_BUILD_REPORT: [buildResult: 'SUCCESS' | 'FAILURE']
 */
def call(Map config = [:]) {
    // Validasi penerima utama
    def primaryRecipientEmail = config.RECIPIENT_EMAIL ?: env.authorEmail
    if (!primaryRecipientEmail?.trim() || primaryRecipientEmail.toString().equalsIgnoreCase('null')) {
        echo "WARN: [sendEmailTemplate] Primary recipient is Invalid (Null/Empty). Skipping email notification."
        return 
    }

    // Gunakan env.BUILD_URL sebagai standar Jenkins, atau sesuaikan jika memakai blue ocean
    def pipelineUrl = env.BUILD_URL ?: 'URL_NOT_AVAILABLE'

    def emailSubject
    def emailBody
    def primaryRecipientName = config.RECIPIENT_NAME ?: env.authorName ?: 'Team'
    
    // Menentukan target environment berdasarkan mode pipeline n8n
    def targetEnv = (env.PIPELINE_MODE && env.PIPELINE_MODE.contains('PROD')) ? 'PRODUCTION' : 'REPOSITORY/DEV'

    switch (config.MAILMODE) {
        case 'APPROVAL_REQUIRED':
            emailSubject = "[APPROVAL REQUIRED] [${targetEnv}] n8n Workflow Deployment - ${env.JOB_NAME} #${env.BUILD_NUMBER}"
            emailBody = """
A deployment of an n8n workflow to the ${targetEnv} environment has been initiated and requires your approval.

Workflow ID: ${env.WORKFLOW_ID}
Triggered by: ${env.authorName} (${env.authorEmail})

The pipeline is waiting for your decision to proceed. Please access the Jenkins pipeline via the link below to approve or reject the deployment.
"""
            break

        case 'POST_BUILD_REPORT':
            def buildResult = config.EXTRA_DATA?.buildResult ?: 'UNKNOWN'
            emailSubject = "[${buildResult}] [${targetEnv}] n8n CI/CD Pipeline - ${env.JOB_NAME} #${env.BUILD_NUMBER}"
            emailBody = """
The n8n CI/CD pipeline has completed with the result: ${buildResult}.

Workflow ID: ${env.WORKFLOW_ID}
Pipeline Mode: ${env.PIPELINE_MODE}

Please review the pipeline logs via the link below for further details.
"""
            break

        default:
            error("Invalid MAILMODE '${config.MAILMODE}' provided to the mail function.")
            break
    }

    def finalBody = """
Hello ${primaryRecipientName},

${emailBody}

Pipeline URL:
${pipelineUrl}

Thank you.

Best regards,  
DevSecOps Team
"""

    // Kirim email
    emailext(
        attachLog: (config.EXTRA_DATA?.buildResult == 'FAILURE'), // Attach log hanya jika gagal
        subject: emailSubject,
        body: finalBody,
        to: "${primaryRecipientEmail}"
        // Hapus cc/bcc jika tidak ada variabel env global untuk itu di project ini
        // cc: env.developersEmail ?: '',
    )
}
