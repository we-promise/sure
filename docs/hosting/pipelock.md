# Pipelock: AI Agent Security Proxy

[Pipelock](https://github.com/luckyPipewrench/pipelock) is an optional security proxy that scans AI agent traffic flowing through Sure. It protects against secret exfiltration, prompt injection, and tool poisoning.

## What Pipelock does

Pipelock runs as a sidecar alongside Sure with two listeners:

| Listener | Port | Direction | What it scans |
|----------|------|-----------|---------------|
| Forward proxy | 8888 | Outbound (Sure to LLM) | DLP (secrets in prompts), response injection |
| MCP reverse proxy | 8889 | Inbound (agent to Sure /mcp) | Prompt injection, tool poisoning, DLP |

### Forward proxy (outbound)

When `HTTPS_PROXY=http://pipelock:8888` is set, outbound HTTPS requests from Faraday-based clients (like `ruby-openai`) are routed through Pipelock. It scans request bodies for leaked secrets and response bodies for prompt injection.

**Covered:** OpenAI API calls via ruby-openai (uses Faraday).
**Not covered:** SimpleFIN, Coinbase, Plaid, or anything using Net::HTTP/HTTParty directly. These bypass `HTTPS_PROXY`.

### MCP reverse proxy (inbound)

External AI assistants that call Sure's `/mcp` endpoint should connect through Pipelock on port 8889 instead of directly to port 3000. Pipelock scans:

- Tool call arguments (DLP, shell obfuscation detection)
- Tool responses (injection payloads)
- Session binding (detects tool inventory manipulation)
- Tool call chains (multi-step attack patterns like recon then exfil)

## Docker Compose setup

The `compose.example.ai.yml` file includes Pipelock. To use it:

1. Download the compose file and Pipelock config:
   ```bash
   curl -o compose.ai.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.ai.yml
   curl -o pipelock.example.yaml https://raw.githubusercontent.com/we-promise/sure/main/pipelock.example.yaml
   ```

2. Start the stack:
   ```bash
   docker compose -f compose.ai.yml up -d
   ```

3. Verify Pipelock is healthy:
   ```bash
   docker compose -f compose.ai.yml ps pipelock
   # Should show "healthy"
   ```

### Connecting external AI agents

External agents should use the MCP reverse proxy port:

```
http://your-server:8889
```

The agent must include the `MCP_API_TOKEN` as a Bearer token in requests. Set this in your `.env`:

```bash
MCP_API_TOKEN=generate-a-random-token
MCP_USER_EMAIL=your@email.com
```

### Running without Pipelock

To use `compose.example.ai.yml` without Pipelock, remove the `pipelock` service and its `depends_on` entries from `web` and `worker`, then unset the proxy env vars (`HTTPS_PROXY`, `HTTP_PROXY`).

Or use the standard `compose.example.yml` which does not include Pipelock.

## Helm (Kubernetes) setup

Enable Pipelock in your Helm values:

```yaml
pipelock:
  enabled: true
  image:
    tag: "0.3.2"
  mode: balanced
```

This creates a separate Deployment, Service, and ConfigMap. The chart auto-injects `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` into web and worker pods.

### Exposing MCP to external agents (Kubernetes)

In Kubernetes, external agents cannot reach the MCP port by default. Enable the Pipelock Ingress:

```yaml
pipelock:
  enabled: true
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: pipelock.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts: [pipelock.example.com]
        secretName: pipelock-tls
```

Or port-forward for testing:

```bash
kubectl port-forward svc/sure-pipelock 8889:8889 -n sure
```

### Monitoring

Enable the ServiceMonitor for Prometheus scraping:

```yaml
pipelock:
  serviceMonitor:
    enabled: true
    interval: 30s
    additionalLabels:
      release: prometheus
```

Metrics are available at `/metrics` on the forward proxy port (8888).

### Eviction protection

For production, enable the PodDisruptionBudget:

```yaml
pipelock:
  pdb:
    enabled: true
    maxUnavailable: 1
```

See the [Helm chart README](../../charts/sure/README.md#pipelock-ai-agent-security-proxy) for all configuration options.

## Pipelock configuration file

The `pipelock.example.yaml` file (Docker Compose) or ConfigMap (Helm) controls scanning behavior. Key sections:

| Section | What it controls |
|---------|-----------------|
| `mode` | `strict` (block threats), `balanced` (warn + block critical), `audit` (log only) |
| `forward_proxy` | Outbound HTTPS scanning (tunnel timeouts, idle timeouts) |
| `dlp` | Data loss prevention (scan env vars, built-in patterns) |
| `response_scanning` | Scan LLM responses for prompt injection |
| `mcp_input_scanning` | Scan inbound MCP requests |
| `mcp_tool_scanning` | Validate tool calls, detect drift |
| `mcp_tool_policy` | Pre-execution rules (shell obfuscation, etc.) |
| `mcp_session_binding` | Pin tool inventory, detect manipulation |
| `tool_chain_detection` | Multi-step attack patterns |
| `websocket_proxy` | WebSocket frame scanning (disabled by default) |
| `logging` | Output format (json/text), verbosity |

For the Helm chart, most sections are configurable via `values.yaml`. For additional sections not covered by structured values (session profiling, data budgets, kill switch), use the `extraConfig` escape hatch:

```yaml
pipelock:
  extraConfig:
    session_profiling:
      enabled: true
      max_sessions: 1000
```

## Modes

| Mode | Behavior | Use case |
|------|----------|----------|
| `strict` | Block all detected threats | Production with sensitive data |
| `balanced` | Warn on low-severity, block on high-severity | Default; good for most deployments |
| `audit` | Log everything, block nothing | Initial rollout, testing |

Start with `audit` mode to see what Pipelock detects without blocking anything. Review the logs, then switch to `balanced` or `strict`.

## Limitations

- Forward proxy only covers Faraday-based HTTP clients. Net::HTTP, HTTParty, and other libraries ignore `HTTPS_PROXY`.
- Docker Compose has no egress network policies. The `/mcp` endpoint on port 3000 is still reachable directly (auth token required). For enforcement, use Kubernetes NetworkPolicies.
- Pipelock scans text content. Binary payloads (images, file uploads) are passed through by default.

## Troubleshooting

### Pipelock container not starting

Check the config file is mounted correctly:
```bash
docker compose -f compose.ai.yml logs pipelock
```

Common issues:
- Missing `pipelock.example.yaml` file
- YAML syntax errors in config
- Port conflicts (8888 or 8889 already in use)

### LLM calls failing with proxy errors

If AI chat stops working after enabling Pipelock:
```bash
# Check Pipelock logs for blocked requests
docker compose -f compose.ai.yml logs pipelock --tail=50
```

If requests are being incorrectly blocked, switch to `audit` mode in the config file and restart:
```yaml
mode: audit
```

### MCP requests not reaching Sure

Verify the MCP upstream is configured correctly:
```bash
# Test from inside the Pipelock container
docker compose -f compose.ai.yml exec pipelock /pipelock healthcheck --addr 127.0.0.1:8888
```

Check that `MCP_API_TOKEN` and `MCP_USER_EMAIL` are set in your `.env` file and that the email matches an existing Sure user.
