---
name: sure-openclaw-build-bootstrap
description: Bootstrap a lean, repeatable Sure build and test environment inside an OpenClaw workspace or similar container/VM. Use when setting up a fresh build environment, auditing missing dependencies before running Sure tests, or turning environment learnings into a repeatable bootstrap flow.
---

# Sure OpenClaw build bootstrap

Use this skill when you need to stand up or re-audit a Sure development environment inside an existing OpenClaw-hosted machine, especially when the goal is to run the Rails test and lint suite without introducing nested Docker or local Postgres state.

## Goal

Create a repeatable bootstrap flow that keeps the environment lean:

- run directly inside the current OpenClaw container or VM when that is the better fit
- prefer the repo devcontainer when the host is a normal non-virtualized machine
- avoid nested Docker or devcontainers as runtime when already inside a constrained VM or container
- prefer rebuildable local services over persistent heavyweight state
- prefer external Postgres for app data when disk is limited

## Workflow

1. Run a baseline environment audit before installing anything.
2. Let the audit decide whether to prefer an in-place bootstrap or the repo devcontainer.
3. Compare the host state with the repo's declared expectations.
4. Install only missing pieces.
5. Keep persistent caches under `/root` or another durable host path.
6. Treat local Redis as acceptable, but avoid local Postgres data unless there is a strong reason.
7. Re-run the audit after each material setup step.

## Step 1, baseline audit

Use the helper script first:

```bash
python3 .openclaw/skills/sure-openclaw-build-bootstrap/scripts/audit_sure_build_env.py /path/to/sure
```

Optional JSON output:

```bash
python3 .openclaw/skills/sure-openclaw-build-bootstrap/scripts/audit_sure_build_env.py /path/to/sure --json
```

The script checks:

- whether the host appears virtualized or containerized
- whether core tools are present
- which Ruby and Bundler versions the repo expects
- whether the current Node version drifts from the devcontainer reference
- available disk space and current repo size
- whether the environment should prefer a lean in-place bootstrap or a devcontainer-first approach

If you need to debug or extend it manually, these are the underlying checks:

```bash
ruby -v
bundle -v
node -v
npm -v
psql --version
redis-server --version
df -h / /root /tmp
du -sh /path/to/sure
cat .ruby-version
grep -n '^BUNDLED WITH$' -A1 Gemfile.lock
grep -n '^ruby ' Gemfile
```

## Current known baseline from the first audit

On the first reference host, the baseline was:

- Ruby: missing
- Bundler: missing
- Node: `v24.14.1`
- npm: `11.11.0`
- `psql`: missing
- `redis-server`: missing
- Sure checkout size: `138M`
- free space on `/`: about `6.8G`
- free space on `/root`: about `6.0G`
- repo requires Ruby `3.4.7`
- `Gemfile.lock` expects Bundler `2.6.7`
- devcontainer reference uses Node `20.x`, PostgreSQL client, and Redis

This tells you the environment cannot run Rails tests yet, but it has enough free space to proceed with a lean bootstrap.

## Decision rules

- If the audit says the host is not virtualized, strongly consider the repo devcontainer as the default setup path.
- If the audit says the host is already virtualized or containerized, prefer a lean in-place bootstrap unless there is a strong reason to nest containers.
- If Ruby is absent, install the repo-required version first.
- If Bundler is absent, install the exact lockfile-compatible version.
- If Node is present but newer than the repo reference, note the drift rather than changing it immediately.
- If `psql` is absent, install client tooling only unless the task explicitly requires local Postgres.
- If Redis is absent, install and run it locally.
- Do not assume devcontainer contents should be mirrored exactly. Use it as reference, not runtime.

## Resources

- `scripts/audit_sure_build_env.py` for a repeatable baseline audit and strategy recommendation.
- `references/baseline-environment-audit.md` for the captured step 1 findings and rationale.
