# Republishing workflows during production deployment

`scripts/deploy-from-git.sh` uses the same publication sequence for the main
workflow and each selected sub-workflow, on Docker and Kubernetes:

1. Validate and stage one workflow with the requested ID. Strip DEV version and
   publication metadata and import as an unpublished draft.
2. Copy the staged file into the target container before interrupting triggers.
3. Look up the workflow through the production API. If it exists, call
   `POST /workflows/{id}/deactivate` and verify that it is unpublished **before**
   running the import. A lookup 404 skips this step for new workflows.
4. Run `n8n import:workflow` with the existing workflow ID and project selection.
5. Read the new production `versionId`; abort if the import left the old version.
6. Call `POST /workflows/{id}/activate` with that explicit `versionId`.
7. Read the workflow again and require `active == true` and
   `activeVersionId == versionId == imported versionId` before reporting success.

This targets n8n's publish/unpublish model and requires the API to expose
`versionId` and `activeVersionId`. The existing `/activate` and `/deactivate`
endpoints are retained for compatibility. The production API key needs workflow
read, activate, and deactivate access. API requests have bounded timeouts and
authorization, HTTP, transport, and invalid-response failures stop deployment.

The previous CLI publish fallback is removed: a CLI exit code alone does not
verify the publication state returned by the running server. Temporary import
files are cleaned up on success and failure. Credential mapping, injected
settings, folder placement, and sub-workflow-first order are preserved.

Triggers are unavailable between unpublish and successful publish. A failed
deployment may leave the workflow unpublished; inspect the Jenkins/n8n error,
fix the cause, and redeploy. There is no automatic rollback. Avoid overlapping
deployments or manual edits to the same workflow during this sequence.

## Validation

```sh
bash -n scripts/deploy-from-git.sh
python3 -m unittest discover -s tests -v
```

The regression tests execute the real Bash script with mocked API, SSH, Docker,
Kubernetes, and PostgreSQL commands. They cover existing/new/inactive workflows,
main/sub-workflow ordering, object/array exports, and failed or stale publication.
They do not replace a deployment and trigger smoke test against the installed
n8n version.

The checked-in Jenkins configuration references Bitbucket repositories. Apply
this script change to the script source actually checked out by Jenkins before
expecting production behavior to change.
