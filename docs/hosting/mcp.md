# MCP Server for External AI Assistants

Sure includes a Model Context Protocol (MCP) server endpoint that allows external AI assistants like Claude.ai, Claude Desktop, GPT agents, or custom AI clients to query and act on your financial data.

## What is MCP?

[Model Context Protocol](https://modelcontextprotocol.io/) is a JSON-RPC 2.0 protocol that enables AI assistants to access structured data and tools from external applications. Instead of copying and pasting financial data into a chat window, your AI assistant can directly query Sure's data through a secure API.

This is useful when:
- You want to use an external AI assistant (Claude, GPT, custom agents) to analyze your Sure financial data
- You prefer to keep your LLM provider separate from Sure
- You're building custom AI agents that need access to financial tools

## Authentication Modes

Sure supports two ways to authenticate MCP clients:

### 1. OAuth 2.0 / dynamic client registration (recommended)

This is the best option for Claude.ai, ChatGPT (via the OpenAI Secure MCP
Tunnel), and other MCP clients that support OAuth. Sure exposes:

- `/.well-known/oauth-protected-resource` (and the resource-scoped
  `/.well-known/oauth-protected-resource/mcp`)
- `/.well-known/oauth-authorization-server`
- `POST /register` for dynamic client registration

These endpoints let a compatible MCP client register a public OAuth client,
redirect you back to Sure for sign-in, and receive a bearer token scoped to
one of Sure's two existing Doorkeeper scopes:

| Scope | Grants |
|-------|--------|
| `read` | MCP read-only: only tools confirmed to perform no mutation (see [Read-only mode](#read-only-mode)) |
| `read_write` | Full MCP access: everything `read` exposes, plus every write-capable tool |

**A client that registers without specifying a scope gets `read`** — least
privilege by default. A client that wants write access must explicitly
request it: pass `"scope": "read_write"` (or `"scope": "read read_write"`) in
the `POST /register` body, or, for a client that only requests scopes at
authorization time, `read_write` during the `/oauth/authorize` step if the
client supports that. Sure never upgrades a client to `read_write` on its
own. Requesting any scope other than `read` or `read_write` fails
registration with `invalid_client_metadata`.

Recommend `read` for ChatGPT, analytics assistants, and any integration that
only needs to see the data. Reserve `read_write` for a client you actually
want making changes (creating tags, updating transactions, and so on).

### 2. Static bearer token via environment variables

This is the fallback for custom agents, scripts, and deployments where OAuth
isn't practical, or where you want to pin the MCP server to a specific Sure
user regardless of which client connects.

Set these environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `MCP_API_TOKEN` | Bearer token for authentication | `your-secret-token-here` |
| `MCP_USER_EMAIL` | Email of the Sure user whose data the assistant can access | `user@example.com` |
| `MCP_API_TOKEN_SCOPE` | Optional. `read` or `read_write` — mirrors the OAuth scopes above. Defaults to `read_write`, matching this token's historical behavior. | `read` |

`MCP_API_TOKEN` and `MCP_USER_EMAIL` are both required for the static-token
flow. OAuth clients using the MCP discovery and dynamic registration
endpoints do not need these variables. An `MCP_API_TOKEN_SCOPE` value other
than `read` or `read_write` is rejected — the token fails to authenticate
rather than silently falling back to full access.

> [!IMPORTANT]
> In ChatGPT's Secure MCP Tunnel UI, selecting "Authentication: None" for the
> tunnel does **not** mean Sure's `/mcp` endpoint is reachable anonymously —
> the tunnel client injects the bearer token locally via `MCP_EXTRA_HEADERS`
> (or equivalent), and Sure still requires and checks it on every request. Do
> not expose `/mcp` without a token (or an OAuth-authenticated client)
> configured on the Sure side.

### Generating a secure token

Generate a random token for `MCP_API_TOKEN`:

```bash
# macOS/Linux
openssl rand -base64 32

# Or use any secure password generator
```

### Choosing the user for static-token auth

The `MCP_USER_EMAIL` must match an existing Sure user's email address. The AI assistant will have access to all financial data for that user's family.

> [!CAUTION]
> The AI assistant can call the MCP tools available to the specified user. This includes reading financial data and write-capable tools such as statement import, goal/category/tag changes, transaction updates, and budget updates. Only set this for users you trust with your AI provider.

## Read-only mode

A connection ends up limited to read-only tools when any of the following is
true — they compose, and any one of them is enough:

| Source | Effect |
|--------|--------|
| OAuth token scoped `read` | That connection only (the normal case — see [Authentication Modes](#authentication-modes)) |
| `MCP_API_TOKEN_SCOPE=read` | The static token only |
| `MCP_READ_ONLY=true` | Kill switch: **every** MCP connection, regardless of how it authenticated, including an OAuth token scoped `read_write` |

Recommended setups:

- **ChatGPT via OAuth (recommended):** register it with the default scope
  (`read`) — no environment variable needed. See
  [Authentication Modes](#authentication-modes).
- **Claude via the static token, keeping ChatGPT read-only:** there is only
  one `MCP_API_TOKEN` per install, so this only works if ChatGPT uses OAuth
  (`read` scope) and the static token — with `MCP_API_TOKEN_SCOPE` unset or
  `read_write` — is reserved for Claude. Two *static* tokens at different
  scopes are not supported; use OAuth for whichever client needs a scope
  different from the static token's.
- **Lock down `/mcp` entirely, regardless of who connects:**
  ```bash
  MCP_READ_ONLY=true
  ```

### What "read-only" actually restricts

Read-only mode is enforced with an explicit allowlist of tool classes whose
implementation was read and confirmed to perform no `INSERT`, `UPDATE`,
`DELETE`, file write, or other mutation — not a naming convention like
"starts with `get_`". Both `tools/list` and `tools/call` consult the same
filtered list, so a write tool is not only hidden from discovery, it also
cannot be invoked by a client that already knows (or guesses) its exact name:
calling `update_transaction` under a read-only credential returns the same
"Unknown tool" error as calling a name that does not exist at all — the
response does not confirm the tool exists but is forbidden.

Allowed in read-only mode: `get_transactions`, `get_recurring_transactions`,
`get_accounts`, `get_holdings`, `get_balance_sheet`, `get_income_statement`,
`get_tags`, `get_categories`, `get_merchants`, and, for users
with preview features enabled, `list_account_statements`,
`get_account_statement`, `get_statement_coverage`, `get_valuations`,
`get_insights`, `get_bills`, `get_bill_details`, `get_paycheck_plan`,
`get_bill_audit`.

Never allowed in read-only mode, even though the name suggests otherwise:
`get_budget` — its default (current-month) path calls
`Budget.find_or_bootstrap`, which creates the month's budget record on first
access. `search_family_files` — non-mutating, but it can surface
uploaded-document contents outside the structured financial data the other
read tools expose, a larger data surface than this mode is meant to grant an
external assistant. Every other excluded tool (`create_goal`, `create_tag`, `update_tag`, `create_category`,
`update_category`, `create_transaction`, `update_transaction`, `delete_transaction`, `update_budget`,
`import_bank_statement`, `upload_account_statement`, `record_valuation`,
`create_bill`, `update_bill`, `record_bill_payment`) performs a real mutation.

### Sessions and read-only mode

This only matters for the `2025-03-26`/`2025-06-18` dialects, which have a
session; `2026-07-28` has none (see [Protocol dialects](#protocol-dialects))
and is authenticated fresh on every request, so there is nothing for it to
preserve or escalate.

An MCP session (`Mcp-Session-Id`) remembers the access mode of the credential
that created it and never grants more than that for the life of the session,
even if a later request on the same session id authenticates with a
read-write token. Sessions created before this feature existed (no stored
access mode) are treated as read-write, matching what every session meant
before read-only mode was introduced.

## Configuration

### Docker Compose

Add the environment variables to your `compose.yml`:

```yaml
x-rails-env: &rails_env
  MCP_API_TOKEN: your-secret-token-here
  MCP_USER_EMAIL: user@example.com
  # Optional — see "Read-only mode" above
  # MCP_API_TOKEN_SCOPE: "read"
  # MCP_READ_ONLY: "true"
```

Both `web` and `worker` services inherit this configuration.

### Kubernetes (Helm)

Add the variables to your `values.yaml` or set them via Secrets:

```yaml
env:
  MCP_API_TOKEN: your-secret-token-here
  MCP_USER_EMAIL: user@example.com
  # Optional — see "Read-only mode" above
  # MCP_API_TOKEN_SCOPE: "read"
  # MCP_READ_ONLY: "true"
```

Or create a Secret and reference it:

```yaml
envFrom:
  - secretRef:
      name: sure-mcp-credentials
```

## Protocol Details

The MCP endpoint is available at:

```
POST /mcp
```

### Authentication

MCP supports OAuth authorization-code flow for clients such as Claude Code.
Clients should discover the protected-resource metadata, register dynamically
(requesting `read` or `read_write` — see [Authentication
Modes](#authentication-modes)), and send the resulting access token as a
Bearer token.

For self-hosted deployments or clients without OAuth support, requests may use
the static `MCP_API_TOKEN` as a Bearer token:

```
Authorization: Bearer <token>
```

That token can come from either:

- an OAuth authorization flow handled by the MCP client, or
- the static `MCP_API_TOKEN` environment variable described above.

### Supported Methods

Sure implements the following JSON-RPC 2.0 methods:

| Method | Description |
|--------|-------------|
| `initialize` | Protocol handshake, returns server info and capabilities |
| `server/discover` | Authenticated capability probe for the 2026-07-28 dialect (see below). Does not require `initialize` first and does not create a session. |
| `tools/list` | Lists available financial tools with schemas |
| `tools/call` | Executes a tool with provided arguments |

A JSON-RPC request without an `id` (a notification, e.g.
`notifications/initialized`) gets `202 Accepted` with an empty body — Sure
never replies with data to a request that declared it wants no reply.

### Protocol dialects

Sure accepts three MCP protocol versions, resolved per request from (in
order) the `MCP-Protocol-Version` header, then `params._meta["io.modelcontextprotocol/protocolVersion"]`,
then the default (`2025-06-18`). If a request sends both the header and the
`_meta` field and they disagree, Sure rejects it with `400 Bad Request`
rather than silently picking one — as does any unrecognized version.

| Version | Notes |
|---------|-------|
| `2025-03-26` | Original MCP HTTP transport. |
| `2025-06-18` | Current default; `initialize` returns an `Mcp-Session-Id`, which subsequent requests may (but need not) send back. |
| `2026-07-28` | [Stateless dialect](https://modelcontextprotocol.io/specification/2026-07-28/changelog): no `initialize` handshake and no session — every request stands on its own, carrying its own protocol version. `tools/list` and `tools/call` results gain `resultType: "complete"` and identify the server via `_meta["io.modelcontextprotocol/serverInfo"]`. `server/discover` is this dialect's capability probe. |

Any client speaking `2026-07-28` works the same way — this is a protocol
dialect, not a feature built for one product. The OpenAI Secure MCP Tunnel
(used by ChatGPT) happens to be one such client; nothing in Sure's MCP code
knows it exists.

`initialize` itself still negotiates its own `protocolVersion` the same way
it always has (request `params.protocolVersion`, falling back to the
default), independent of this per-request header/`_meta` resolution. A
`2026-07-28` client has no reason to call it — that dialect's spec removes
the handshake — but nothing stops Sure from answering it if one does.

### Available Tools

The MCP endpoint exposes the same tool registry used by Sure's built-in assistant. Clients should treat `tools/list` as the source of truth.

At the time of writing, `tools/list` includes:

| Tool | Description |
|------|-------------|
| `get_transactions` | Search transactions with filters (exact names or ids), sorting by date or absolute amount, and pagination |
| `get_recurring_transactions` | Detected and manual recurring transactions (subscriptions, bills, salaries) with expected dates and per-currency totals |
| `get_accounts` | Accounts with ids and current balances; pass `include_balance_series: true` for a period-bounded history series |
| `get_holdings` | Query investment holdings |
| `get_balance_sheet` | Net worth, assets and liabilities with a configurable history period and interval |
| `get_income_statement` | Income and expenses for a period, with optional monthly series, prior-period comparison and account filtering |
| `get_budget` | Budget summary for a month, with optional prior months |
| `get_merchants` | Merchants with the ids `update_transaction` accepts and the exact names `get_transactions` filters on |
| `get_tags` | Tags with pagination |
| `get_categories` | Categories with hierarchy and pagination |
| `create_goal` | Create a savings goal linked to depository accounts |
| `create_tag` / `update_tag` | Manage tags |
| `create_category` / `update_category` | Manage categories |
| `update_transaction` | Edit a transaction's metadata (name, notes, category, merchant, tags) |
| `create_transaction` | Create a new transaction on one of the user's accounts |
| `delete_transaction` | Permanently delete a transaction from the ledger (destructive, irreversible) |
| `update_budget` | Update budget allocations for a month |
| `import_bank_statement` | Import bank statement data |
| `search_family_files` | Search documents uploaded through the import flow. Note this is the vector-store document index, not the Statement Vault — statements archived via `upload_account_statement` are not searchable through it |

### Preview Tools

These additional tools appear only when the MCP user has opted into preview
features (Settings → Preferences). Until then they are absent from `tools/list`,
and calling one by name returns an "Unknown tool" error. The Statement Vault
tools additionally require the user to be an admin or member, matching the
permissions enforced in the web UI.

| Tool | Description |
|------|-------------|
| `upload_account_statement` | Store a statement document (PDF/CSV/XLSX) in the Statement Vault; deduplicates by SHA-256 |
| `list_account_statements` | List vault documents with their SHA-256, period, linked account and review status |
| `get_account_statement` | One statement's details and its reconciliation checks against the ledger — present only once someone has entered the statement's opening/closing balances in the web UI, since nothing extracts them from the document. Does not return the file: stored documents are served only to a signed-in browser session |
| `get_statement_coverage` | Month-by-month statement coverage for an account: `covered`, `missing`, `mismatched`, `ambiguous`, `duplicate`, `not_expected`, each with a reconciliation status |
| `record_valuation` | Record an account's value on a date, with a required source citation |
| `get_valuations` | List recorded valuations newest first, including the citation stored in each entry's notes; the read pair for `record_valuation` |
| `get_insights` | Read the proactive insights feed (spending anomalies, cash-flow warnings, subscription audits and more) without marking anything read |
| `get_bills` | List bills, subscriptions and other recurring obligations with each one's current payment state |
| `get_bill_details` | One bill's full configuration, open occurrences, payment history, price-change history and cost analytics |
| `get_paycheck_plan` | Income plan sliced into pay periods: what is due before the next payday, what stays reserved for later bills, what is safe to spend |
| `get_bill_audit` | Deterministic bills review: possible duplicates, price changes, trials about to convert, upcoming renewals, long-overdue bills and undeclared recurring patterns |
| `create_bill` | Create a bill, subscription, installment plan or income schedule |
| `update_bill` | Update one bill's configuration; amount changes apply from today forward |
| `record_bill_payment` | Record a partial payment against a bill's open occurrence, or settle it in full |

Because tool calls never pass through the Bills pages' controllers, the bills
tools re-check the family's recurring-transactions feature gate (Settings →
Recurring transactions) and the MCP user's per-account access on every call.
With the feature disabled they return an error result instead of data, bills
tied to accounts the user cannot see are never returned, and the write tools
refuse series on accounts shared with the user read-only.

They exist for agents that maintain a document-backed record of a family's
wealth over time. See
[Wealth history with an external agent harness](../llm-guides/wealth-agent-harness.md).

## Example Requests

### Initialize

Handshake to verify protocol version and capabilities:

```bash
curl -X POST https://your-sure-instance/mcp \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize"
  }'
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "capabilities": {
      "tools": {}
    },
    "serverInfo": {
      "name": "sure",
      "version": "1.0"
    }
  }
}
```

### List Tools

Get available tools with their schemas:

```bash
curl -X POST https://your-sure-instance/mcp \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list"
  }'
```

Response includes tool names, descriptions, and JSON schemas for parameters.

### OAuth discovery

MCP clients that support OAuth can discover Sure's metadata automatically:

```bash
curl https://your-sure-instance/.well-known/oauth-protected-resource
curl https://your-sure-instance/.well-known/oauth-authorization-server
```

The authorization-server metadata includes:

- `authorization_endpoint`: `https://your-sure-instance/oauth/authorize`
- `token_endpoint`: `https://your-sure-instance/oauth/token`
- `registration_endpoint`: `https://your-sure-instance/register`
- `scopes_supported`: `["read", "read_write"]`

The protected-resource metadata's `resource` field identifies `/mcp` itself
(`https://your-sure-instance/mcp`), not the whole origin — it is the one
endpoint actually behind Bearer auth. The same metadata is also served at the
resource-scoped path, `/.well-known/oauth-protected-resource/mcp`, for
clients that construct that URL from the resource identifier themselves
instead of following the `resource_metadata` value in a 401's
`WWW-Authenticate` header.

### Call a Tool

Execute a tool to get transactions:

```bash
curl -X POST https://your-sure-instance/mcp \
  -H "Authorization: Bearer your-secret-token" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "get_transactions",
      "arguments": {
        "start_date": "2024-01-01",
        "end_date": "2024-01-31"
      }
    }
  }'
```

Response:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "[{\"id\":\"...\",\"amount\":-45.99,\"date\":\"2024-01-15\",\"name\":\"Coffee Shop\"}]"
      }
    ]
  }
}
```

## Security Considerations

### Transient Session Isolation

The MCP controller creates a **transient session** for each request. This prevents session state leaks that could expose other users' data if the Sure instance is using impersonation features.

Each MCP request:
1. Authenticates the token
2. Loads the authorized Sure user
3. Creates a temporary session scoped to that user
4. Executes the tool call
5. Discards the session

This ensures the AI assistant can only access data for the intended user.

### Pipelock Security Scanning

For production deployments, we recommend using [Pipelock](https://github.com/luckyPipewrench/pipelock) to scan MCP traffic for security threats.

Pipelock provides:
- **DLP scanning**: Detects secrets being exfiltrated through tool calls
- **Prompt injection detection**: Identifies attempts to manipulate the AI
- **Tool poisoning detection**: Prevents malicious tool call sequences
- **Policy enforcement**: Block or warn on suspicious patterns
- **Signed receipts**: Produces verifiable evidence for mediated MCP decisions when the flight recorder is configured with storage and a signing key

See the [Pipelock documentation](pipelock.md) and the example configuration in `compose.example.ai.yml` for setup instructions.

### Network Security

The `/mcp` endpoint is exposed on the same port as the web UI (default 3000). For hardened deployments:

**Docker Compose:**
- The MCP endpoint is protected by the `MCP_API_TOKEN` but is reachable on port 3000
- For additional security, use Pipelock's MCP reverse proxy (port 8889) which adds scanning
- See `compose.example.ai.yml` for a Pipelock configuration

**Kubernetes:**
- Use NetworkPolicies to restrict access to the MCP endpoint
- Route external agents through Pipelock's MCP reverse proxy
- See the [Helm chart documentation](../../charts/sure/README.md) for Pipelock ingress setup

Only `/mcp` traffic itself needs to go through Pipelock. The OAuth and
discovery endpoints — `/.well-known/oauth-protected-resource`,
`/.well-known/oauth-authorization-server`, `/register`, `/oauth/authorize`,
`/oauth/token` — are served directly by Sure and should stay that way; there
is no supported configuration where a reverse proxy fakes a 404 on these to
simulate "no OAuth support". Doing so does not disable OAuth, it just breaks
discovery for clients that rely on it, while the static-token fallback keeps
working regardless.

## Production Deployment

For a production-ready setup with security scanning:

1. **Download the example configuration:**

   ```bash
   curl -o compose.ai.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.ai.yml
   curl -o pipelock.example.yaml https://raw.githubusercontent.com/we-promise/sure/main/pipelock.example.yaml
   ```

2. **Set your MCP credentials in `.env`:**

   ```bash
   MCP_API_TOKEN=your-secret-token
   MCP_USER_EMAIL=user@example.com
   ```

3. **Start the stack:**

   ```bash
   docker compose -f compose.ai.yml up -d
   ```

4. **Connect your AI assistant to the Pipelock MCP proxy:**

   ```
   http://your-server:8889
   ```

The Pipelock proxy (port 8889) scans all MCP traffic before forwarding to Sure's `/mcp` endpoint.

## Connecting AI Assistants

### Claude.ai

Sure's Settings UI is already geared toward Claude.ai OAuth integrations:

1. Open **Settings -> Integrations** in Claude.ai
2. Click **Add integration**
3. Paste your Sure MCP URL
4. Claude redirects you to Sure to sign in and authorize access

If you are using Pipelock, use the reverse-proxy URL on port `8889`. Otherwise use the app URL ending in `/mcp`.

### Claude Desktop

If your Claude Desktop build expects a raw MCP endpoint instead of an OAuth integration flow, point it at:

- `http://your-server:8889` when using Pipelock, or
- `http://your-server:3000/mcp` for direct access

Use either the client's OAuth support or a bearer token, depending on what that build supports.

### Cursor and other native MCP clients

Desktop MCP clients such as Cursor and VS Code authenticate with OAuth Dynamic Client Registration (`POST /register`) and then open a browser for consent. Native clients register a private-use redirect URI rather than an `https://` callback, for example:

- Cursor desktop: `cursor://anysphere.cursor-mcp/oauth/callback`
- Newer Cursor IDE/CLI builds: `http://localhost:8787/callback`
- Cursor web: `https://www.cursor.com/agents/mcp/oauth/callback`
- VS Code extensions: `vscode://...`

Sure accepts those native-app URI schemes, loopback `http://` callbacks, and `https://` callbacks. After you authorize in the browser, the client exchanges the authorization code (PKCE) for a bearer token and calls `/mcp`.

If OAuth is inconvenient (CI, scripts, or a client that cannot complete the browser flow), use the static `MCP_API_TOKEN` bearer token instead.

### Custom Agents

Any AI agent that supports JSON-RPC 2.0 can connect to the MCP endpoint. The agent should:

1. Send a POST request to `/mcp`
2. Include the `Authorization: Bearer <token>` header
3. Use the JSON-RPC 2.0 format for requests
4. Handle the protocol methods: `initialize`, `tools/list`, `tools/call`

## Troubleshooting

### "unauthorized" error

**Symptom:** Requests return HTTP 401 with "unauthorized"

**Fix:** Verify one of these is true:

- The OAuth flow completed successfully, the token carries `read` or
  `read_write` scope, and the client is sending the issued bearer token
- The static token matches `MCP_API_TOKEN`
- If you are using the static-token flow, `MCP_USER_EMAIL` matches an existing Sure user, and `MCP_API_TOKEN_SCOPE` (if set) is `read` or `read_write`

### Static token works, but the user still gets rejected

**Symptom:** Requests return HTTP 401 even though the bearer token matches `MCP_API_TOKEN`

**Fix:** Either the `MCP_USER_EMAIL` does not match an existing user, or
`MCP_API_TOKEN_SCOPE` is set to something other than `read` or `read_write`
(an invalid scope fails the token rather than falling back to full access).
Check that:
- The email is correct
- The user exists in the database
- There are no typos or extra spaces
- `MCP_API_TOKEN_SCOPE`, if set, is exactly `read` or `read_write`

### OAuth token authenticates but write tools are missing

**Symptom:** `tools/list` succeeds but tools like `update_transaction` are
absent, or `tools/call` on one returns "Unknown tool"

**Fix:** This is expected for a token scoped `read` — see [Read-only
mode](#read-only-mode). Re-authorizing an existing connection with a wider
scope does **not** work: Doorkeeper validates a `/oauth/authorize` scope
request against the client application's own registered scopes, and a
client registered with only `read` stored can never be granted `read_write`
that way. Two options actually grant it:

1. **Re-register the client** with `"scope": "read_write"` in the `POST
   /register` body — for Claude or ChatGPT, remove and re-add the connector.
   This only helps if the client actually sends a `scope` field; check its
   own settings for a scope or permissions option.
2. **Edit the application's scopes directly**, for a client that doesn't
   expose a scope option: a `super_admin` can open
   `/oauth/applications/:id/edit` (Doorkeeper's admin UI, mounted and gated
   on `super_admin?` — see `config/initializers/doorkeeper.rb`), set scopes
   to `read_write`, then have the user re-authorize.

### Pipelock connection refused

**Symptom:** AI assistant cannot connect to Pipelock's MCP proxy (port 8889)

**Fix:**
1. Verify Pipelock is running: `docker compose ps pipelock`
2. Check Pipelock health: `docker compose exec pipelock /pipelock healthcheck --addr 127.0.0.1:8888`
3. Verify the port is exposed in your `compose.yml`

## See Also

- [External AI Assistant Configuration](ai.md#external-ai-assistant) - Configure Sure's chat to use an external agent
- [Pipelock Security Proxy](pipelock.md) - Set up security scanning for MCP traffic
- [Model Context Protocol Specification](https://modelcontextprotocol.io/) - Official MCP documentation
