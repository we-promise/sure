# Langfuse

This app can send traces of all LLM interactions to [Langfuse](https://langfuse.com) for debugging and usage analytics.  Find them here [on
GitHub](https://github.com/langfuse/langfuse) and look at their [Open
Source statement](https://langfuse.com/open-source).

## Prerequisites

1. Create a Langfuse Cloud project, or use a self-hosted instance compatible with [v4 ingestion](https://langfuse.com/docs/compatibility).
2. Copy the **public key** and **secret key** from the project's settings.

## Configuration

Set the following environment variables for the Rails app:

```bash
LANGFUSE_PUBLIC_KEY=your_public_key
LANGFUSE_SECRET_KEY=your_secret_key
# Optional if self‑hosting or using a non‑default domain
LANGFUSE_HOST=https://your-langfuse-domain.com
```

In Docker setups, add the variables to `compose.yml` and the accompanying `.env` file.

The initializer reads these values on boot and automatically enables tracing. If the keys are absent, the app runs normally without Langfuse.

## What Gets Tracked

* Chat responses
* Categorization and merchant detection/enrichment
* Bill suggestions and PDF processing
* Family document searches

Each call records the prompt, model, response, and token usage when available.

## Viewing Traces

After starting the app with the variables set, visit your Langfuse dashboard to see observations grouped under `openai.*`, `anthropic.*`, and `search_family_files` traces. Chat roots and their generations carry the same session ID and hashed user ID.

## Langfuse v4

Sure uses the native Ruby OpenTelemetry SDK and OTLP exporter. The existing keys and `LANGFUSE_HOST` remain unchanged; Sure sends completed observations to `/api/public/otel/v1/traces` with `x-langfuse-ingestion-version: 4`. Request and response data live on the root observation, with operation-specific data on its children. No separate trace input/output is written.

Observations are buffered in memory and exported in batches. The exporter retries transient failures; failed batches and overflowing buffers can lose observations. Normal process exit flushes pending observations with a 30-second timeout. Forced termination can lose buffered data. Tracing failures are reported through OpenTelemetry logging and do not change LLM results. This is best-effort telemetry, not durable delivery.

`evals:langfuse:run_experiment` writes one root observation per dataset item, with experiment identity, input, expected output, actual output, and item metadata. Scores reference that observation through `/api/public/scores`. Dataset CRUD and pagination remain unchanged. Experiment ingestion is explicitly flushed before scoring, and export failures are reported as failed items. Provider calls made in evaluation batches retain their separate operational traces; their token costs are not assigned to individual experiment items.

## Production cutover

Follow the [project migration workflow](https://raw.githubusercontent.com/langfuse/skills/main/skills/langfuse/references/v4-project-migration.md) and inspect the [Cloud migration status](https://cloud.langfuse.com/v4-migration). Langfuse Cloud manages its own server upgrade; only Sure needs redeploying. Cloud removes legacy ingestion on November 16, 2026.

Before deploying to production, configure a separate non-production project and exercise chat, a batched provider operation, a failed request, document search, and a dataset experiment. Inspect hierarchy, root input/output, model/usage, session IDs on every cost-bearing generation, session costs, and experiment scores. Repository tests verify the exported format and HTTP contract; they do not verify Cloud ingestion or project configuration.

Inspect active Legacy rules in [Evaluators](https://cloud.langfuse.com/project/~/evals). Provider roots are candidate targets for observation evaluators; experiment-item roots are candidate targets for dataset evaluator successors. These are code-derived suggestions, not project-verified contracts. Check each rule's filters, sampling and variable mappings against actual observations. Create successors disabled, validate them, and obtain approval before enabling them; retain disabled legacy rules for rollback. Do not restore deprecated trace input/output to avoid migrating evaluators.

Inspect Project Settings > Integrations for blob-storage, Mixpanel, PostHog, or other exports. Confirm downstream consumers support enriched observations before changing export sources. Preserve existing credentials, schedules, and formats.

Keep the prior Sure image available during rollout. Reverting to it restores legacy ingestion only while Cloud still accepts that ingestion path. After the Cloud cutoff, fix forward or temporarily disable tracing by removing its keys; rolling back Sure cannot restore a removed Cloud API.
