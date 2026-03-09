# MCP Server for External AI Assistants

Sure includes a Model Context Protocol (MCP) server endpoint that allows external AI assistants like Claude Desktop, GPT agents, or custom AI clients to query your financial data.

## What is MCP?

[Model Context Protocol](https://modelcontextprotocol.io/) is a JSON-RPC 2.0 protocol that enables AI assistants to access structured data and tools from external applications. Instead of copying and pasting financial data into a chat window, your AI assistant can directly query Sure's data through a secure API.

This is useful when:
- You want to use an external AI assistant (Claude, GPT, custom agents) to analyze your Sure financial data
- You prefer to keep your LLM provider separate from Sure
- You're building custom AI agents that need access to financial tools

## Prerequisites

To enable the MCP endpoint, you need to set two environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `MCP_API_TOKEN` | Bearer token for authentication | `your-secret-token-here` |
| `MCP_USER_EMAIL` | Email of the Sure user whose data the assistant can access | `user@example.com` |

Both variables are **required**. The endpoint will not activate if either is missing.

### Generating a secure token

Generate a random token for `MCP_API_TOKEN`:

```bash
# macOS/Linux
openssl rand -base64 32

# Or use any secure password generator
```

### Choosing the user

The `MCP_USER_EMAIL` must match an existing Sure user's email address. The AI assistant will have access to all financial data for that user's family.

> [!CAUTION]
> The AI assistant will have **read access to all financial data** for the specified user. Only set this for users you trust with your AI provider.

## Configuration

### Docker Compose

Add the environment variables to your `compose.yml`:

```yaml
x-rails-env: &rails_env
  MCP_API_TOKEN: your-secret-token-here
  MCP_USER_EMAIL: user@example.com
```

Both `web` and `worker` services inherit this configuration.

### Kubernetes (Helm)

Add the variables to your `values.yaml` or set them via Secrets:

```yaml
env:
  MCP_API_TOKEN: your-secret-token-here
  MCP_USER_EMAIL: user@example.com
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

All requests must include the `MCP_API_TOKEN` as a Bearer token:

```
Authorization: Bearer <MCP_API_TOKEN>
```

### Supported Methods

Sure implements the following JSON-RPC 2.0 methods:

| Method | Description |
|--------|-------------|
| `initialize` | Protocol handshake, returns server info and capabilities |
| `tools/list` | Lists available financial tools with schemas |
| `tools/call` | Executes a tool with provided arguments |

### Available Tools

The MCP endpoint exposes these financial tools:

| Tool | Description |
|------|-------------|
| `get_transactions` | Retrieve transaction history with filtering |
| `get_accounts` | Get account information and balances |
| `get_holdings` | Query investment holdings |
| `get_balance_sheet` | Current financial position (assets, liabilities, net worth) |
| `get_income_statement` | Income and expenses over a period |
| `import_bank_statement` | Import bank statement data |
| `search_family_files` | Search uploaded documents in the vault |

These are the same tools used by Sure's builtin AI assistant.

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
2. Loads the user specified in `MCP_USER_EMAIL`
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

See the [Pipelock documentation](pipelock.md) and the example configuration in `compose.example.pipelock.yml` for setup instructions.

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

### Claude Desktop

Configure Claude Desktop to use Sure's MCP server:

1. Open Claude Desktop settings
2. Add a new MCP server
3. Set the endpoint to `http://your-server:8889` (if using Pipelock) or `http://your-server:3000/mcp`
4. Add the authorization header: `Authorization: Bearer your-secret-token`

### Custom Agents

Any AI agent that supports JSON-RPC 2.0 can connect to the MCP endpoint. The agent should:

1. Send a POST request to `/mcp`
2. Include the `Authorization: Bearer <token>` header
3. Use the JSON-RPC 2.0 format for requests
4. Handle the protocol methods: `initialize`, `tools/list`, `tools/call`

## Troubleshooting

### "MCP endpoint not configured" error

**Symptom:** Requests return HTTP 503 with "MCP endpoint not configured"

**Fix:** Ensure both `MCP_API_TOKEN` and `MCP_USER_EMAIL` are set as environment variables and restart Sure.

### "unauthorized" error

**Symptom:** Requests return HTTP 401 with "unauthorized"

**Fix:** Verify the `Authorization` header contains the correct token: `Bearer <MCP_API_TOKEN>`

### "MCP user not configured" error

**Symptom:** Requests return HTTP 503 with "MCP user not configured"

**Fix:** The `MCP_USER_EMAIL` does not match an existing user. Check that:
- The email is correct
- The user exists in the database
- There are no typos or extra spaces

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
