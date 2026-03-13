# Langfuse

This app can send traces of all LLM interactions to [Langfuse](https://langfuse.com) for debugging and usage analytics.  Find them here [on
GitHub](https://github.com/langfuse/langfuse) and look at their [Open
Source statement](https://langfuse.com/open-source).

## Prerequisites

1. Create a Langfuse project (self‑hosted or using their cloud offering).
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

## System instructions from Langfuse (optional)

Prompts are managed only in Langfuse; the app does not store or edit prompts in the database. When `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` are set, the built-in assistant loads instructions from Langfuse so experiments and versioning happen there.

**Main chat:** Create a prompt named **`default_instructions`** with variables: `preferred_currency_symbol`, `preferred_currency_iso_code`, `preferred_currency_default_precision`, `preferred_currency_default_format`, `preferred_currency_separator`, `preferred_currency_delimiter`, `preferred_date_format`, `current_date`.

**Intro / welcome flow:** Create a prompt named **`intro_instructions`** with variables: `preferred_currency_symbol`, `preferred_currency_iso_code`, `preferred_date_format`, `current_date`.

If a prompt is missing or retrieval fails, the app falls back to built-in default text. Chat generations that use a Langfuse-loaded prompt attach prompt name, version, and content to the trace metadata.

## What Gets Tracked

* `chat_response`
* `auto_categorize`
* `auto_detect_merchants`

Each call records the prompt, model, response, and token usage when available. When system instructions are loaded from Langfuse, the prompt version and content are included in the generation metadata.

## Viewing Traces

After starting the app with the variables set, visit your Langfuse dashboard to see traces and generations grouped under the `openai.*` traces.
