# LLM Configuration Guide

This document explains how Sure uses Large Language Models (LLMs) for AI features and how to configure them for your deployment.

## Overview

Sure includes an AI assistant that can help users understand their financial data by answering questions about accounts, transactions, income, expenses, net worth, and more. The assistant uses LLMs to process natural language queries and provide insights based on the user's financial data.

> [!CAUTION]
> Only `gpt-4.1` was ever supported prior to `v0.6.5-alpha*` builds!

> 👉 Help us by taking a structured approach to your issue reporting. 🙏

## Quickstart: OpenAI Token

The easiest way to get started with AI features in Sure is to use OpenAI:

1. Get an API key from [OpenAI](https://platform.openai.com/api-keys)
2. Set the environment variable:
   ```bash
   OPENAI_ACCESS_TOKEN=sk-proj-...your-key-here...
   ```
3. (Re-)Start Sure (both `web` and `worker` services!) and the AI assistant will be available to use after you agree/allow via UI option

That's it! Sure will use OpenAI's with a default model (currently `gpt-4.1`) for all AI operations.

## Local vs. Cloud Inference

### Cloud Inference (Recommended for Most Users)

**What it means:** The LLM runs on remote servers (like OpenAI's infrastructure), and your app sends requests over the internet.

| Pros                             | Cons |
|------                            |------|
| Zero setup - works immediately   | Requires internet connection |
| Always uses the latest models    | Data leaves your infrastructure (though transmitted securely) |
| No hardware requirements         | Per-request costs |
| Scales automatically             | Dependent on provider availability |
| Regular updates and improvements | |

**When to use:**
- You're new to LLMs
- You want the best performance without setup
- You don't have powerful hardware (GPU with large VRAM)
- You're okay with cloud-based processing
- You're running a managed instance

### Local Inference (Self-Hosted)

**What it means:** The LLM runs on your own hardware using tools like Ollama, LM Studio, or LocalAI.

| Pros                                                | Cons |
|------                                               |------|
| Complete data privacy - nothing leaves your network | Requires significant hardware (see below) |
| No per-request costs after initial setup            | Setup and maintenance overhead |
| Works offline                                       | Models may be less capable than latest cloud offerings |
| Full control over models and updates                | You manage updates and improvements |
| Can be more cost-effective at scale                 | Performance depends on your hardware |

**Hardware Requirements:**

The amount of VRAM (GPU memory) you need depends on the model size:

- **Minimum (8GB VRAM):** Can run 7B parameter models like `llama3.2:7b` or `gemma2:7b`
  - Works for basic chat functionality
  - May struggle with complex financial analysis
  
- **Recommended (16GB+ VRAM):** Can run 13B-14B parameter models like `llama3.1:13b` or `qwen2.5:14b`
  - Good balance of performance and hardware requirements
  - Handles most financial queries well
  
- **Ideal (24GB+ VRAM):** Can run 30B+ parameter models or run smaller models with higher precision
  - Best quality responses
  - Complex reasoning about financial data
  
**CPU-only inference:** Possible but extremely slow (10-100x slower). Not recommended for production use.

**When to use:**
- Privacy is critical (regulated industries, sensitive financial data)
- You have the required hardware
- You're comfortable with technical setup
- You want to minimize ongoing costs
- You need offline functionality

## Cloud Providers

Sure supports any OpenAI-compatible API endpoint. Here are tested providers:

### OpenAI (Primary Support)

```bash
OPENAI_ACCESS_TOKEN=sk-proj-...
# No other configuration needed

# Optional: Request timeout in seconds (default: 60)
# OPENAI_REQUEST_TIMEOUT=60
```

**Recommended models:**
- `gpt-4.1` - Default, best balance of speed and quality
- `gpt-5` - Latest model, highest quality (more expensive)
- `gpt-4o-mini` - Cheaper, good quality

**Pricing:** See [OpenAI Pricing](https://openai.com/api/pricing/)

### Google Gemini (via OpenRouter)

[OpenRouter](https://openrouter.ai/) provides access to many models including Gemini:

```bash
OPENAI_ACCESS_TOKEN=your-openrouter-api-key
OPENAI_URI_BASE=https://openrouter.ai/api/v1
OPENAI_MODEL=google/gemini-2.0-flash-exp
```

**Why OpenRouter?**
- Single API for multiple providers
- Competitive pricing
- Automatic fallbacks
- Usage tracking

**Recommended Gemini models via OpenRouter:**
- `google/gemini-2.5-flash` - Fast and capable
- `google/gemini-2.5-pro` - High quality, good for complex queries

### Anthropic Claude (via OpenRouter)

```bash
OPENAI_ACCESS_TOKEN=your-openrouter-api-key
OPENAI_URI_BASE=https://openrouter.ai/api/v1
OPENAI_MODEL=anthropic/claude-3.5-sonnet
```

**Recommended Claude models:**
- `anthropic/claude-sonnet-4.5` - Excellent reasoning, good with financial data
- `anthropic/claude-haiku-4.5` - Fast and cost-effective

### Other Providers

Any service offering an OpenAI-compatible API should work:
- [Groq](https://groq.com/) - Fast inference, free tier available
- [Together AI](https://together.ai/) - Various open models
- [Anyscale](https://www.anyscale.com/) - Llama models
- [Replicate](https://replicate.com/) - Various models

## Local LLM Setup (Ollama)

[Ollama](https://ollama.ai/) is the recommended tool for running LLMs locally.

### Installation

1. Install Ollama:
   ```bash
   # macOS
   brew install ollama
   
   # Linux
   curl -fsSL https://ollama.com/install.sh | sh
   
   # Windows
   # Download from https://ollama.com/download
   ```

2. Start Ollama:
   ```bash
   ollama serve
   ```

3. Pull a model:
   ```bash
   # Smaller, faster (requires 8GB VRAM)
   ollama pull gemma2:7b
   
   # Balanced (requires 16GB VRAM)
   ollama pull llama3.1:13b
   
   # Larger, more capable (requires 24GB+ VRAM)
   ollama pull qwen2.5:32b
   ```

### Configuration

Configure Sure to use Ollama:

```bash
# Dummy token (Ollama doesn't need authentication)
OPENAI_ACCESS_TOKEN=ollama-local

# Ollama API endpoint
OPENAI_URI_BASE=http://localhost:11434/v1

# Model you pulled
OPENAI_MODEL=llama3.1:13b

# Optional: enable debug logging in the AI chat
AI_DEBUG_MODE=true 
```

**Important:** When using Ollama or any custom provider:
- You **must** set `OPENAI_MODEL` - the system cannot default to `gpt-4.1` as that model won't exist in Ollama
- The `OPENAI_ACCESS_TOKEN` can be any non-empty value (Ollama ignores it)
- If you don't set a model, chats will fail with a validation error

### Docker Compose Example

```yaml
services:
  sure:
    environment:
      - OPENAI_ACCESS_TOKEN=ollama-local
      - OPENAI_URI_BASE=http://ollama:11434/v1
      - OPENAI_MODEL=llama3.1:13b
      - AI_DEBUG_MODE=true # Optional: enable debug logging in the AI chat
    depends_on:
      - ollama
  
  ollama:
    image: ollama/ollama:latest
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    # Uncomment if you have an NVIDIA GPU
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: 1
    #           capabilities: [gpu]

volumes:
  ollama_data:
```

## Model Recommendations

> [!CAUTION]
> **REMINDER:** Only `gpt-4.1` was ever supported prior to `v0.6.5-alpha*` builds!

> 👉 Help us by taking a structured approach to your testing of the models mentioned below. 🙏

### For Chat Assistant

The AI assistant needs to understand financial context and perform **function/tool** calling:

**Cloud:**
- **Best:** `gpt-4.1` or `gpt-5` - Most reliable, best function calling
- **Good:** `anthropic/claude-4.5-sonnet` - Excellent reasoning
- **Budget:** `google/gemini-2.5-flash` - Fast and affordable

**Local:**
- **Best:** `qwen3-30b` - Strong function calling and reasoning (24GB+ VRAM, 14GB at 3bit quantised )
- **Good:** `openai/gpt-oss-20b` - Solid performance (12GB VRAM)
- **Budget:** `qwen3-8b`, `llama3.1-8b` - Minimal hardware (8GB VRAM), still supports tool calling

### For Auto-Categorization

Transaction categorization doesn't require function calling:

**Cloud:**
- **Best:** Same as chat - `gpt-4.1` or `gpt-5`
- **Budget:** `gpt-4o-mini` - Much cheaper, still very accurate

**Local:**
- Any model that works for chat will work for categorization
- This is less demanding than chat, so smaller models may suffice
- Some models don't support structured outputs, please validate when using.

### For Merchant Detection

Similar requirements to categorization:

**Cloud:**
- Same recommendations as auto-categorization

**Local:**
- Same recommendations as auto-categorization

## Configuration via Settings UI

For self-hosted deployments, you can configure AI settings through the web interface:

1. Go to **Settings** → **Self-Hosting**
2. Scroll to the **AI Provider** section
3. Configure:
   - **OpenAI Access Token** - Your API key
   - **OpenAI URI Base** - Custom endpoint (leave blank for OpenAI)
   - **OpenAI Model** - Model name (required for custom endpoints)

**Note:** Settings in the UI override environment variables. If you change settings in the UI, those values take precedence.

## AI Cache Management

Sure caches AI-generated results (like auto-categorization and merchant detection) to avoid redundant API calls and costs. However, there are situations where you may want to clear this cache.

### What is the AI Cache?

When AI rules process transactions, Sure stores:
- **Enrichment records**: Which attributes were set by AI (category, merchant, etc.)
- **Attribute locks**: Prevents rules from re-processing already-handled transactions

This caching means:
- Transactions won't be sent to the LLM repeatedly
- Your API costs are minimized
- Processing is faster on subsequent rule runs

### When to Reset the AI Cache

You might want to reset the cache when:

1. **Switching LLM models**: Different models may produce better categorizations
2. **Improving prompts**: After system updates with better prompts
3. **Fixing miscategorizations**: When AI made systematic errors
4. **Testing**: During development or evaluation of AI features

> [!CAUTION]
> Resetting the AI cache will cause all transactions to be re-processed by AI rules on the next run. This **will incur API costs** if using a cloud provider.

### How to Reset the AI Cache

**Via UI (Recommended):**
1. Go to **Settings** → **Rules**
2. Click the menu button (three dots)
3. Select **Reset AI cache**
4. Confirm the action

The cache is cleared asynchronously in the background. You'll see a confirmation message when the process starts.

**Automatic Reset:**
The AI cache is automatically cleared for all users when the OpenAI model setting is changed. This ensures that the new model processes transactions fresh.

### What Happens When Cache is Reset

1. **AI-locked attributes are unlocked**: Transactions can be re-enriched
2. **AI enrichment records are deleted**: The history of AI changes is cleared
3. **User edits are preserved**: If you manually changed a category after AI set it, your change is kept

### Cost Implications

Before resetting the cache, consider:

| Scenario | Approximate Cost |
|----------|------------------|
| 100 transactions | $0.05-0.20 |
| 1,000 transactions | $0.50-2.00 |
| 10,000 transactions | $5.00-20.00 |

*Costs vary by model. Use `gpt-4o-mini` for lower costs.*

**Tips to minimize costs:**
- Use narrow rule filters before running AI actions
- Reset cache only when necessary
- Consider using local LLMs for bulk re-processing

## Observability with Langfuse

Sure includes built-in support for [Langfuse](https://langfuse.com/), an open-source LLM observability platform.

### What is Langfuse?

Langfuse helps you:
- Track all LLM requests and responses
- Monitor costs per request
- Measure response latency
- Debug failed requests
- Analyze usage patterns
- Optimize prompts based on real data

### Setup

1. Create a free account at [Langfuse Cloud](https://cloud.langfuse.com/) or [self-host Langfuse](https://langfuse.com/docs/deployment/self-host)

2. Get your API keys from the Langfuse dashboard

3. Configure Sure:
   ```bash
   LANGFUSE_PUBLIC_KEY=pk-lf-...
   LANGFUSE_SECRET_KEY=sk-lf-...
   LANGFUSE_HOST=https://cloud.langfuse.com  # or your self-hosted URL
   ```

4. Restart Sure

All LLM operations will now be logged to Langfuse, including:
- Chat messages and responses
- Auto-categorization requests
- Merchant detection
- Token usage and costs
- Response times

### Langfuse Features in Sure

- **Automatic tracing:** Every LLM call is automatically traced
- **Session tracking:** Chat sessions are tracked with a unique session ID
- **User anonymization:** User IDs are hashed before sending to Langfuse
- **Cost tracking:** Token usage is logged for cost analysis
- **Error tracking:** Failed requests are logged with error details

### Viewing Traces

1. Go to your Langfuse dashboard
2. Navigate to **Traces**
3. You'll see traces for:
   - `openai.chat_response` - Chat assistant interactions
   - `openai.auto_categorize` - Transaction categorization
   - `openai.auto_detect_merchants` - Merchant detection

### Privacy Considerations

**What's sent to Langfuse:**
- Prompts and responses
- Model names
- Token counts
- Timestamps
- Session IDs
- Hashed user IDs (not actual user data)

**What's NOT sent:**
- User email addresses
- User names
- Unhashed user IDs
- Account credentials

**For maximum privacy:** Self-host Langfuse on your own infrastructure.

## Testing and Evaluation

### Manual Testing

Test your AI configuration:

1. Go to the Chat interface in Sure
2. Try these test prompts:
   - "Show me my total spending this month"
   - "What are my top 5 spending categories?"
   - "How much do I have in savings?"

3. Verify:
   - Responses are relevant
   - Function calls work (you should see "Analyzing your data..." briefly)
   - Numbers match your actual data

### Automated Evaluation

Sure doesn't currently include automated evals, but you can build them using Langfuse:

1. **Collect baseline responses:** Run test prompts and save responses
2. **Create evaluation dataset:** Use Langfuse datasets feature
3. **Run evaluations:** Test new models/prompts against the dataset
4. **Compare results:** Use Langfuse's comparison tools

### Benchmarking Models

To compare models for your use case:

1. **Speed Test:**
   - Send the same prompt to different models
   - Measure time to first token (TTFT)
   - Measure overall response time

2. **Quality Test:**
   - Create a set of 10-20 realistic financial questions
   - Get responses from each model
   - Manually rate accuracy and helpfulness

3. **Cost Test:**
   - Calculate cost per interaction based on token usage
   - Factor in your expected usage volume
   - Consider speed vs. cost tradeoffs

### Example Evaluation Queries

Good test queries that exercise different capabilities:

- **Simple retrieval:** "What's my checking account balance?"
- **Aggregation:** "Total spending on restaurants last month?"
- **Comparison:** "Am I spending more or less than last year?"
- **Analysis:** "What are my biggest expenses this quarter?"
- **Forecasting:** "Based on my spending, when will I reach $10k savings?"

## Cost Considerations

### Cloud Costs

Typical costs for OpenAI (as of early 2025):

- **gpt-4.1:** ~$5-15 per 1M input tokens, ~$15-60 per 1M output tokens
- **gpt-5:** ~2-3x more expensive than gpt-4.1
- **gpt-4o-mini:** ~$0.15 per 1M input tokens (very cheap)

**Typical usage:**
- Chat message: 500-2000 tokens (input) + 100-500 tokens (output)
- Auto-categorization: 1000-3000 tokens per 25 transactions
- Cost per chat message: $0.01-0.05 for gpt-4.1

**Optimization tips:**
1. Use `gpt-4o-mini` for categorization
2. Use Langfuse to identify expensive prompts
3. Cache results when possible
4. Consider local LLMs for high-volume operations

### Local Costs

**One-time costs:**
- GPU hardware: $500-2000+ depending on VRAM needs
- Setup time: 2-8 hours

**Ongoing costs:**
- Electricity: ~$0.10-0.50 per hour of GPU usage
- Maintenance: Occasional updates and monitoring

**Break-even analysis:**

If you process 10,000 messages/month:
- Cloud (gpt-4.1): ~$200-500/month
- Local (amortized): ~$50-100/month after hardware cost
- Break-even: 6-12 months depending on hardware cost

**Recommendation:** Start with cloud, switch to local if costs exceed $100-200/month.

### Hybrid Approach

You can mix providers:

```python
# Example: Use local for categorization, cloud for chat
# Categorization (high volume, lower complexity)
CATEGORIZATION_PROVIDER=ollama
CATEGORIZATION_MODEL=gemma2:7b

# Chat (lower volume, higher complexity)
CHAT_PROVIDER=openai
CHAT_MODEL=gpt-4.1
```

**Note:** Sure currently uses a single provider for all operations, but this could be customized.

## Troubleshooting

### "Messages is invalid" Error

**Symptom:** Cannot start a chat, see validation error

**Cause:** Using a custom provider (like Ollama) without setting `OPENAI_MODEL`

**Fix:**
```bash
# Make sure all three are set for custom providers
OPENAI_ACCESS_TOKEN=ollama-local  # Any non-empty value
OPENAI_URI_BASE=http://localhost:11434/v1
OPENAI_MODEL=your-model-name  # REQUIRED!
```

### Model Not Found

**Symptom:** Error about model not being available

**Cloud:** Check that you're using a valid model name for your provider

**Local:** Make sure you've pulled the model:
```bash
ollama list  # See what's installed
ollama pull model-name  # Install a model
```

### Slow Responses

**Symptom:** Long wait times for AI responses

**Cloud:**
- Switch to a faster model (e.g., `gpt-4o-mini` or `gemini-2.0-flash-exp`)
- Check your internet connection
- Verify provider status page

**Local:**
- Check GPU utilization (should be near 100% during inference)
- Try a smaller model
- Ensure you're using GPU, not CPU
- Check for thermal throttling

### No Provider Available

**Symptom:** "Provider not found" or similar error

**Fix:**
1. Check `OPENAI_ACCESS_TOKEN` is set
2. For custom providers, verify `OPENAI_URI_BASE` and `OPENAI_MODEL`
3. Restart Sure after changing environment variables
4. Check logs for specific error messages

### High Costs

**Symptom:** Unexpected bills from cloud provider

**Analysis:**
1. Check Langfuse for usage patterns
2. Look for unusually long conversations
3. Check if you're using an expensive model

**Optimization:**
1. Switch to cheaper model for categorization
2. Consider local LLM for high-volume tasks
3. Implement rate limiting if needed
4. Review and optimize system prompts

## Advanced Topics

### Custom System Prompts

Sure's AI assistant uses a system prompt that defines its behavior. The prompt is defined in `app/models/assistant/configurable.rb`.

To customize:
1. Fork the repository
2. Edit the `default_instructions` method
3. Rebuild and deploy

**What you can customize:**
- Tone and personality
- Response format
- Rules and constraints
- Domain expertise

### Function Calling

The assistant uses OpenAI's function calling (tool use) to access user data:

**Available functions:**
- `get_transactions` - Retrieve transaction history
- `get_accounts` - Get account information
- `get_balance_sheet` - Current financial position
- `get_income_statement` - Income and expenses

These are defined in `app/models/assistant/function/`.

### Vector Store (Document Search)

Sure's AI assistant can search documents that have been uploaded to a family's vault. Under the hood, documents are indexed in a **vector store** so the assistant can retrieve relevant passages when answering questions (Retrieval-Augmented Generation).

#### How It Works

1. When a user uploads a document to their family vault, it is automatically pushed to the configured vector store.
2. When the assistant needs financial context from uploaded files, it calls the `search_family_files` function.
3. The vector store returns the most relevant passages, which the assistant uses to answer the question.

#### Supported Backends

| Backend | Status | Best For | Requirements |
|---------|--------|----------|--------------|
| **OpenAI** (default) | ready | Cloud deployments, zero setup | `OPENAI_ACCESS_TOKEN` |
| **Pgvector** | scaffolded | Self-hosted, full data privacy | PostgreSQL with `pgvector` extension |
| **Qdrant** | scaffolded | Self-hosted, dedicated vector DB | Running Qdrant instance |

#### Configuration

##### OpenAI (Default)

No extra configuration is needed. If you already have `OPENAI_ACCESS_TOKEN` set for the AI assistant, document search works automatically. OpenAI manages chunking, embedding, and retrieval.

```bash
# Already set for AI chat — document search uses the same token
OPENAI_ACCESS_TOKEN=sk-proj-...
```

##### Pgvector (Self-Hosted)

> [!CAUTION]
> Only `OpenAI` has been implemented!

Use PostgreSQL's pgvector extension for fully local document search:

```bash
VECTOR_STORE_PROVIDER=pgvector
```

> **Note:** The pgvector adapter is currently a skeleton. A future release will add full support including embedding model configuration.

##### Qdrant (Self-Hosted)

> [!CAUTION]
> Only `OpenAI` has been implemented!

Use a dedicated Qdrant vector database:

```bash
VECTOR_STORE_PROVIDER=qdrant
QDRANT_URL=http://localhost:6333   # Default if not set
QDRANT_API_KEY=your-api-key        # Optional, for authenticated instances
```

Docker Compose example:

```yaml
services:
  sure:
    environment:
      - VECTOR_STORE_PROVIDER=qdrant
      - QDRANT_URL=http://qdrant:6333
    depends_on:
      - qdrant

  qdrant:
    image: qdrant/qdrant:latest
    ports:
      - "6333:6333"
    volumes:
      - qdrant_data:/qdrant/storage

volumes:
  qdrant_data:
```

> **Note:** The Qdrant adapter is currently a skeleton. A future release will add full support including collection management and embedding configuration.

#### Verifying the Configuration

You can check whether a vector store is properly configured from the Rails console:

```ruby
VectorStore.configured?          # => true / false
VectorStore.adapter              # => #<VectorStore::Openai:...>
VectorStore.adapter.class.name   # => "VectorStore::Openai"
```

#### Supported File Types

The following file extensions are supported for document upload and search:

`.pdf`, `.txt`, `.md`, `.csv`, `.json`, `.xml`, `.html`, `.css`, `.js`, `.rb`, `.py`, `.docx`, `.pptx`, `.xlsx`, `.yaml`, `.yml`, `.log`, `.sh`

#### Privacy Notes

- **OpenAI backend:** Document content is sent to OpenAI's API for indexing and search. The same privacy considerations as the AI chat apply.
- **Pgvector / Qdrant backends:** All data stays on your infrastructure. No external API calls are made for document search.

### Multi-Model Setup

Currently not supported out of the box, but you could:
1. Create multiple provider instances
2. Add routing logic to select provider based on task
3. Update controllers to specify which provider to use

### Rate Limiting

To prevent abuse or runaway costs:

1. Use [Rack::Attack](https://github.com/rack/rack-attack) (already included)
2. Configure in `config/initializers/rack_attack.rb`
3. Limit requests per user or globally

Example:
```ruby
# Limit chat creation to 10 per minute per user
throttle('chats/create', limit: 10, period: 1.minute) do |req|
  req.session[:user_id] if req.path == '/chats' && req.post?
end
```

## Resources

- [OpenAI Documentation](https://platform.openai.com/docs)
- [Ollama Documentation](https://github.com/ollama/ollama)
- [OpenRouter Documentation](https://openrouter.ai/docs)
- [Langfuse Documentation](https://langfuse.com/docs)
- [Sure GitHub Repository](https://github.com/we-promise/sure)

## Support

For issues with AI features:
1. Check this documentation first
2. Search [existing GitHub issues](https://github.com/we-promise/sure/issues)
3. Open a new issue with:
   - Your configuration (redact API keys!)
   - Error messages
   - Steps to reproduce
   - Expected vs. actual behavior

---

**Last Updated:** October 2025
