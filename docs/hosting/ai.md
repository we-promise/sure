# LLM Configuration Guide

Sure uses LLMs for the AI assistant, auto-categorization, and merchant detection.

## Quick Start

### OpenAI (Simplest)

```bash
OPENAI_ACCESS_TOKEN=sk-proj-...your-key-here...
```

That's it. Restart Sure and AI features are enabled.

### OpenRouter (Access to Multiple Providers)

```bash
OPENAI_ACCESS_TOKEN=your-openrouter-api-key
OPENAI_URI_BASE=https://openrouter.ai/api/v1
OPENAI_MODEL=google/gemini-2.0-flash-exp
```

### Local LLMs (Ollama, LM Studio)

```bash
OPENAI_ACCESS_TOKEN=ollama-local
OPENAI_URI_BASE=http://localhost:11434/v1
OPENAI_MODEL=qwen3:30b
```

## Tested Models

### Cloud
- **OpenAI GPT-4.1 / GPT-5** - Best quality, reliable function calling
- **Google Gemini 2.5 Flash** - Fast and capable (via OpenRouter)

### Local
- **Best:** `qwen3-30b` - Strong function calling and reasoning (24GB+ VRAM, 14GB at 3-bit quantized)
- **Good:** `openai/gpt-oss-20b` - Solid performance (12GB VRAM at 4-bit quantized)
- **Budget:** `qwen3-14b` - Minimal hardware (8GB VRAM at 4-bit quantized), supports tool calling

## Configuration via Settings UI

Self-hosted deployments can configure AI settings through the web interface:

**Settings** → **Self-Hosting** → **AI Provider**

UI settings override environment variables.

## Observability with Langfuse

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_HOST=https://cloud.langfuse.com
```

All LLM calls are automatically traced with session tracking, cost tracking, and error logging.

## Evaluation Framework

Test and compare different models using the built-in eval framework.

### Commands

```bash
rake evals:list_datasets                              # List available datasets
rake evals:import_dataset[path]                       # Import from YAML
rake evals:run[dataset,provider,model]                # Run evaluation
rake evals:compare[run_ids]                           # Compare multiple runs
rake evals:report[run_id]                             # Show detailed report
rake evals:smoke_test                                 # Quick test with 5 samples
rake evals:ci_regression[dataset,provider,model,threshold]  # CI regression testing
```

### Langfuse Integration

```bash
bin/rails 'evals:langfuse:check'                                    # Verify Langfuse connection
bin/rails 'evals:langfuse:upload_dataset[categorization_golden_v1]' # Upload dataset to Langfuse
bin/rails 'evals:langfuse:run_experiment[categorization_golden_v1,gpt-4.1]' # Run experiment
```

Experiments create in Langfuse:
- **Dataset** - Named `eval_<your_dataset_name>` with all samples
- **Traces** - One per sample showing input/output
- **Scores** - Accuracy scores (0.0 or 1.0) for each trace
- **Dataset Runs** - Links traces to dataset items for comparison

In Langfuse you can compare runs side-by-side, filter by score/model, and track accuracy over time.

### Export Golden Dataset

Export manually categorized transactions as a golden dataset:

```bash
# Basic usage
rake evals:export_manual_categories[family-uuid]

# With environment variables
FAMILY_ID=uuid OUTPUT=custom_path.yml LIMIT=1000 rake evals:export_manual_categories
```

Exports transactions where the category was manually set by the user (not by AI/rules/Plaid). Output matches the standard dataset format for direct import with `rake evals:import_dataset[path]`.
