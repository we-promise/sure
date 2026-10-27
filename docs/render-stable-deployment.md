# Stable releases on Render

`publish.yml` deploys stable releases to the existing `sure-app` project using
GitHub's **stable** environment. The alpha/demo path is unchanged.

## One-time setup outside this repository

Configure these **environment secrets** in GitHub Settings → Environments → stable:

- `RENDER_APP_WEB_DEPLOY_HOOK_URL`: unmodified hook URL for `sure-web-6y53`
  (`srv-dauth3vpn0mc739470bg`).
- `RENDER_APP_WORKER_DEPLOY_HOOK_URL`: unmodified hook URL for `sure-worker-6y53`
  (`srv-dauthr7pn0mc7394a270`).
- `RENDER_API_KEY`: a Render API key able to read both services and their deploys.
  Hooks trigger deployment; the API key is required to verify completion.
  A key stored in an operator's automation environment is **not** automatically
  available in GitHub Actions. Never paste keys or hook URLs into issues or logs.

No GitHub environment variables are required. The workflow explicitly identifies
both services and `https://sure-web-6y53.onrender.com`; update those constants if
moving the installation. This is not the `app.sure.am` installation.

Ensure environment deployment rules permit release tags (`v*`). Required reviewers
will pause the workflow for approval; omit that requirement if unattended deployment
is intended. Keep Render auto-deploy disabled: these are prebuilt image services,
not Git-connected builds. The workflow does not provision resources or change DNS.

Before the first rollout, verify a recoverable PostgreSQL backup and storage backup,
review release upgrade instructions (including encryption-key migration), and confirm
shared web/worker configuration. `bin/docker-entrypoint` runs `db:prepare` when the
web server starts. The old worker can run during web migrations; releases must be
backward-compatible with it. Breaking migrations require a separately coordinated
maintenance rollout, not this automated path.

## Release flow

Merge this change into the branch from which the release tag will be created
**before** pushing the tag. Push a conventional stable `vMAJOR.MINOR.PATCH` tag.
A literal Git tag `stable` is not supported. Alpha, beta, RC, branch, schedule and
manual-dispatch runs do not trigger this deployment job.

After CI and multi-architecture image publication succeed, the job:

1. Validates all configuration and reads both target services before any deploy.
2. Calls the web hook with `imgURL=ghcr.io/we-promise/sure:MAJOR.MINOR.PATCH`.
3. Polls the returned deployment ID (up to ten minutes) until it is `live`, and
   checks that Render reports the requested image and a digest.
4. Checks `/up` and `/sessions/new` on the configured web origin.
5. Deploys the worker using the same version, waits for its exact deployment, and
   verifies its digest matches the web deployment.

The GitHub environment reports the job outcome. The job does not wait for mobile,
Helm or GitHub Release creation; it waits for successful image publication. Each hook request explicitly supplies the release image, regardless of the
service's configured default tag. Version tags must not be overwritten. Production runs share a
concurrency group and do not cancel an in-progress deployment. GitHub may replace
an older pending run with a newer one; this is not a FIFO release queue.

## Failure and recovery

Inspect the Actions job and the Render service's deployment events. HTTP errors
are deliberately sanitized to avoid logging credentials; no trigger is automatically
retried. A timeout or network error does not prove the deployment was cancelled.
If Render returns 202 (queued without an ID), the job fails rather than claiming
unverified success; inspect the queued deployment before retrying.

The rollout is **not atomic**: web may be updated while worker deployment fails.
No automatic rollback is attempted, because database migrations may already have
run. Resolve the failure and rerun the failed job for the same release only after
checking Render for active/queued deployments. Do not rerun an older release after
a newer one has deployed unless intentionally rolling back. For rollback, select a
known compatible image version for both services and assess schema compatibility
first; restore backups only through a separately approved recovery procedure.

## Local tooling tests

```sh
python3 -m unittest discover -s .github/deployment -p 'test_*.py'
```

These tests mock all network calls and run in reusable CI before image publication.
They never read real credentials or deploy services.

References: [Render deploy hooks](https://render.com/docs/deploy-hooks),
[deployment status API](https://api-docs.render.com/reference/retrieve-deploy).
