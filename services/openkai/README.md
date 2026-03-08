# OpenKai-Sure: Financial AI Assistant with Memory

A memory-powered financial assistant that integrates with [Sure](https://github.com/we-promise/sure) as an external AI assistant. Each family gets isolated memory via a Knowledge Graph, and the assistant learns from every conversation.

## Architecture

```
Sure (Rails)  ←SSE→  Pipelock  ←→  OpenKai-Sure (Node.js)
                                      ├─ Claude API (via Pipelock fwd proxy)
                                      ├─ Sure REST API (/api/v1/*)
                                      └─ Per-family SQLite + KG memory
```

- **SSE streaming** matches Sure's `External::Client` contract
- **REST API client** calls Sure's `/api/v1/*` endpoints directly for financial data
- **Per-family memory** — each family gets an isolated SQLite database with FTS5 search
- **Onboarding** — first session learns about the user, generates a profile
- **Budget tracking** — global + per-family daily limits on Claude API spend

## Quick Start

### With Docker Compose (recommended)

```bash
# In the Sure repo root
docker compose -f compose.example.ai.yml --profile openkai up
```

Required env vars in `.env`:
```
ANTHROPIC_API_KEY=sk-ant-...
SURE_API_KEY=your-sure-api-key          # Sure API key with read scope (X-Api-Key)
EXTERNAL_ASSISTANT_URL=http://openkai:3210/v1/chat/completions
EXTERNAL_ASSISTANT_TOKEN=your-shared-secret
ASSISTANT_TYPE=external
```

### Local Development

```bash
cd services/openkai
pnpm install
pnpm dev
```

Required env vars:
```
ANTHROPIC_API_KEY=sk-ant-...
OPENKAI_AUTH_TOKEN=your-shared-secret
SURE_API_URL=http://localhost:3000
SURE_API_KEY=your-sure-api-key
```

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `ANTHROPIC_API_KEY` | (required) | Claude API key |
| `OPENKAI_AUTH_TOKEN` | (required) | Token Sure uses to authenticate |
| `SURE_API_URL` | `http://web:3000` | Sure's REST API base URL |
| `SURE_API_KEY` | (required) | Sure API key with read scope |
| `HTTPS_PROXY` | `http://pipelock:8888` | Pipelock forward proxy (for Claude API) |
| `OPENKAI_PORT` | `3210` | Listen port |
| `OPENKAI_HOST` | `0.0.0.0` | Listen host |
| `OPENKAI_DAILY_BUDGET_USD` | `5.00` | Global daily spend limit |
| `OPENKAI_PER_FAMILY_DAILY_BUDGET_USD` | `1.00` | Per-family daily limit |
| `OPENKAI_MAX_CACHED_TENANTS` | `50` | Max open SQLite DBs |
| `OPENKAI_DATA_DIR` | `/data` | Root data directory |
| `LOG_LEVEL` | `info` | Log level |

## Tools (Claude → Sure REST API)

| Tool | Endpoint | Use case |
|------|----------|----------|
| `get_transactions` | `GET /api/v1/transactions` | Search transactions with filters (date, category, merchant, amount) |
| `get_accounts` | `GET /api/v1/accounts` | List accounts with balances |
| `get_holdings` | `GET /api/v1/holdings` | Investment portfolio data |
| `get_categories` | `GET /api/v1/categories` | Look up category IDs for filtering |
| `get_merchants` | `GET /api/v1/merchants` | Look up merchant IDs |
| `get_tags` | `GET /api/v1/tags` | Look up tag IDs |

Claude computes aggregations (income statements, balance sheet analysis) from raw data — no server-side LLM needed.

## Model Routing

| Query Type | Model | Triggers |
|-----------|-------|---------|
| Default | Sonnet | All queries (floor — Haiku too weak for persona) |
| Complex | Opus | "should I", "refinance", "invest", "tax strategy", "forecast", word count >100 |

## Data Layout

```
/data/tenants/
  family-<id>/
    knowledge.db          # KG entities, relations, FTS5 index
    brain/
      user.md             # Financial profile (generated from onboarding)
      assistant.md        # Name + persona
      self-model.md       # Auto-generated reflection
```

## Health Check

```bash
curl http://localhost:3210/health
```

## Stack

- TypeScript, Node.js 22, Fastify
- SQLite (better-sqlite3) with FTS5 for BM25 search
- Anthropic SDK for Claude API
- No Ollama dependency — all LLM calls go through Claude
