# Stable releases on Render

`publish.yml` deploys stable releases to the existing `sure-app` project using
GitHub's **stable** environment. It follows the same hook-and-health-check sequence
as the existing alpha/demo deployment; no Render API key is required.

## Configuration

The **stable** GitHub environment needs these two secrets:

- `RENDER_APP_WEB_DEPLOY_HOOK_URL`: web service deploy hook.
- `RENDER_APP_WORKER_DEPLOY_HOOK_URL`: worker deploy hook.

No additional environment variables are required. The app URL is explicitly
`https://sure-web-6y53.onrender.com`, not `app.sure.am`.
The existing environment reviewer gate remains in effect. Approve each deployment,
or change environment protection separately if unattended deployment is desired.
Keep Render auto-deploy disabled for these prebuilt image services.

## Release flow

Merge this workflow into the release source branch before pushing a stable
`vMAJOR.MINOR.PATCH` tag. A literal Git tag `stable` is not supported. Prerelease,
branch, scheduled and manual-dispatch runs do not trigger the app deployment.

After image publication succeeds, the job follows the demo sequence:

1. Check that both hook URLs and the web URL are configured.
2. Trigger the web hook with the exact versioned GHCR image (`v` prefix removed).
3. Wait 60 seconds, then poll `/up` up to 24 times at 15-second intervals.
4. Smoke-test `/sessions/new`.
5. Trigger the worker hook with the same versioned image.

Deployments are serialized without cancelling an active rollout. GitHub can replace
an older pending run; concurrency is not a FIFO release queue.

**Success means deployment requests were accepted and web health checks passed.**
The old web instance can satisfy those checks. This does not verify that the new
web image is live or that worker deployment completed. Check Render deployment
events for those guarantees. Stronger API-backed verification is separate work.

## First rollout and recovery

Before updating this existing installation, verify database/storage recovery and
release upgrade prerequisites, including encryption-key migration. Web startup runs
`db:prepare`; the old worker may still run during migrations. Breaking migrations
need a coordinated maintenance rollout rather than this automated path.

If a job fails, inspect Render before retrying: hook-triggered deployments are
asynchronous and may continue after the workflow stops. There is no automatic
rollback. Before a rollback, check schema compatibility and choose a known release
for both services. Do not rerun an older release after a newer rollout unless that
rollback is intentional.
