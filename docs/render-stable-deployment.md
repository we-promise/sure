# Render release deployment verification

Both `deploy_demo` and `deploy_app` in `publish.yml` use the same Python helper,
`.github/deployment/deploy_render.py`. Release policy remains environment-specific:
alpha tags deploy to **demo**, and stable version-tag pushes deploy to **stable**.
Existing reviewer gates and concurrency groups are preserved.

## Setup required before enabling this follow-up

Add a **`RENDER_API_KEY` environment secret to both demo and stable**. Each key must
be able to read its target services and deployment statuses. An operator's existing
credential is not automatically available to GitHub Actions. This is required for
status verification, not for triggering deployment hooks. Never put keys or hook
URLs into repository files or logs.

Existing configuration is reused:

- **demo**: `RENDER_DEMO_WEB_DEPLOY_HOOK_URL`,
  `RENDER_DEMO_WORKER_DEPLOY_HOOK_URL`, and the `RENDER_DEMO_URL` variable.
- **stable**: `RENDER_APP_WEB_DEPLOY_HOOK_URL` and
  `RENDER_APP_WORKER_DEPLOY_HOOK_URL`. The web URL remains explicitly configured as
  `https://sure-web-6y53.onrender.com`, not `app.sure.am`.

Service IDs are taken from the environment's hook URLs; no new service-ID variables
are needed. Before any trigger, the helper validates the hook host/path and checks
that the two services have the expected web/worker roles and use the Sure image.
Configure the hooks for the intended installation: their environment placement is
the source of truth for deployment targets.

## Verification

After successful image publication, both jobs:

1. Validate the tag against their configured stable/alpha channel and preflight
   all credentials and both services before triggering any deployment.
2. Trigger the web hook with the exact versioned GHCR image.
3. Poll the returned deployment ID (up to ten minutes) until `live`, verifying
   the requested image reference and a nonempty image digest.
4. Check `/up` and `/sessions/new`.
5. Trigger and verify the worker deployment, comparing its digest with web.

This verifies rollout completion for the requested image, unlike `/up` alone,
which can be satisfied by an old instance. It does not prove provider syncs or
background jobs work correctly. Unit tests use mocked network responses and run
in reusable CI; they do not constitute a live deployment rehearsal.

## Release and recovery

Merge the workflow into the release source branch before tagging. Existing
reviewer gates still need approval. Deployments are serialized without cancelling
an active rollout; GitHub concurrency is not a FIFO release queue. Do not rerun an
older release after a newer deployment unless intentionally rolling back.

Verify backups and upgrade prerequisites before updating an installation. Web
startup runs `db:prepare`; old workers can remain active during migrations. This
rollout is not atomic, and breaking migrations require coordinated maintenance.

HTTP errors are sanitized and redirects rejected to protect credentials. Trigger
requests are not retried automatically: an ambiguous failure may have started a
deployment. A queued response without a deployment ID fails verification rather
than claiming success. Inspect Render for active/queued deployments before retrying.
A worker failure can leave web on the new version. No automatic rollback is attempted
because database migrations might already have run; assess schema compatibility
before selecting a previous image or restoring data.

## Tests

```sh
python3 -m unittest discover -s .github/deployment -p 'test_*.py'
```

References: [Render deploy hooks](https://render.com/docs/deploy-hooks),
[deployment status API](https://api-docs.render.com/reference/retrieve-deploy).
