# Pipelock: AI Agent Security Proxy

[Pipelock](https://github.com/luckyPipewrench/pipelock) is an optional security proxy that scans AI agent traffic flowing through Sure. It protects against secret exfiltration, prompt injection, and tool poisoning.

## What Pipelock does

Pipelock runs as a separate proxy service alongside Sure with two listeners:

| Listener | Port | Direction | What it scans |
|----------|------|-----------|---------------|
| Forward proxy | 8888 | Outbound (Sure to LLM) | Destination, SSRF, rate, budget, CONNECT-header DLP, and receipt controls for HTTPS tunnels |
| MCP reverse proxy | 8889 | Inbound (agent to Sure /mcp) | Prompt injection, tool poisoning, DLP |

### Forward proxy (outbound)

When `HTTPS_PROXY=http://pipelock:8888` is set, outbound HTTPS requests from clients that honor the variable are routed through Pipelock. The default Sure examples don't configure TLS interception, so Pipelock can control the tunnel destination and connection but can't read encrypted request or response bodies. Body scanning requires TLS interception plus installing Pipelock's CA in the client container.

Faraday-based OpenAI calls honor the proxy variables. Some provider clients may open direct connections, and Docker Compose doesn't enforce a network route that prevents bypass.

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

4. Optional: enable signed action receipts.

   Pipelock's flight recorder is on by default, but it writes nothing until it has a writable evidence directory and a receipt-signing key. Create the directories yourself first (so they are owned by your host user, not root), then generate the key with the Pipelock image so you do not need the binary installed locally:

   ```bash
   mkdir -p pipelock-evidence pipelock-keys
   # --out must be an absolute path inside the container. The key is written
   # 0600 owned by uid 1000, which is the user the Pipelock proxy runs as.
   docker run --rm -v "$PWD/pipelock-keys:/keys" ghcr.io/luckypipewrench/pipelock:3.4.0@sha256:2e6caa43967a5ef19cacbce00188d829c1b5de1eb0ad304a51d2085f32c5694c \
     signing key generate --purpose receipt-signing --out /keys/flight-recorder-signing.key --id sure-compose
   ```

   If your host user is not uid 1000, use this variant instead so the mounted key and evidence directory are readable and writable by the same user that runs the Pipelock service. `compose.example.ai.yml` already has `user: "${PIPELOCK_UID:-1000}:${PIPELOCK_GID:-1000}"` on the `pipelock` service, so export those variables in the same shell before restarting, or put them in your `.env` file:

   ```bash
   export PIPELOCK_UID="$(id -u)" PIPELOCK_GID="$(id -g)"
   docker run --rm --user "$PIPELOCK_UID:$PIPELOCK_GID" -v "$PWD/pipelock-keys:/keys" ghcr.io/luckypipewrench/pipelock:3.4.0@sha256:2e6caa43967a5ef19cacbce00188d829c1b5de1eb0ad304a51d2085f32c5694c \
     signing key generate --purpose receipt-signing --out /keys/flight-recorder-signing.key --id sure-compose
   ```

   Then uncomment the `pipelock-evidence` and `pipelock-keys` volume mounts in `compose.example.ai.yml`, uncomment `flight_recorder.dir` and `flight_recorder.signing_key_path` in `pipelock.example.yaml`, and restart Pipelock from the same shell if you exported `PIPELOCK_UID` and `PIPELOCK_GID`:

   ```bash
   docker compose -f compose.ai.yml restart pipelock
   ```

   Print the public verifier key when you need to hand receipts to another system:

   ```bash
   docker compose -f compose.ai.yml exec pipelock /pipelock signing pubkey --config /etc/pipelock/pipelock.yaml
   ```

### Connecting external AI agents

External agents should use the MCP reverse proxy port:

```text
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
    tag: "3.4.0@sha256:2e6caa43967a5ef19cacbce00188d829c1b5de1eb0ad304a51d2085f32c5694c"
  mode: balanced
```

This creates a separate Deployment, Service, and ConfigMap. The chart auto-injects `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` into web and worker pods.

Sure pins Pipelock 3.4.0 by tag and multi-architecture image digest. Read the [Pipelock release notes](https://github.com/luckyPipewrench/pipelock/releases/tag/v3.4.0) before overriding that pin.

### Signed action receipts

Pipelock can write hash-chained, Ed25519-signed receipts for proxied decisions. This is the audit trail that proves what crossed the Pipelock boundary and what policy verdict was applied.

The chart exposes `pipelock.flightRecorder`, but recording is inert until you mount both storage and a signing key:

```bash
# --out must be an absolute path; "$PWD/..." writes the key into the current directory.
pipelock signing key generate --purpose receipt-signing --out "$PWD/flight-recorder-signing.key" --id sure-k8s
kubectl create namespace sure
kubectl create secret generic sure-pipelock-receipts \
  --namespace sure \
  --from-file=flight-recorder-signing.key=./flight-recorder-signing.key
```

If you don't have the `pipelock` binary installed, generate the key with the pinned image instead: `docker run --rm -v "$PWD:/out" ghcr.io/luckypipewrench/pipelock:3.4.0@sha256:2e6caa43967a5ef19cacbce00188d829c1b5de1eb0ad304a51d2085f32c5694c signing key generate --purpose receipt-signing --out /out/flight-recorder-signing.key --id sure-k8s`.

Example Helm values using an existing PVC named `sure-pipelock-evidence`:

```yaml
pipelock:
  enabled: true
  flightRecorder:
    enabled: true
    dir: /var/lib/pipelock/evidence
    signingKeyPath: /run/secrets/pipelock/flight-recorder-signing.key
    requireReceipts: false
    redact: true
  extraVolumes:
    - name: pipelock-evidence
      persistentVolumeClaim:
        claimName: sure-pipelock-evidence
    - name: pipelock-receipt-key
      secret:
        secretName: sure-pipelock-receipts
        # 0440 (group-read), not 0400: the chart runs Pipelock as uid 1000 with
        # fsGroup 1000, so the secret file is owned root:1000. A 0400 file would
        # be unreadable by the non-root process and Pipelock would crash on
        # startup with a key-load error. 0440 lets the fsGroup read it.
        defaultMode: 0440
  extraVolumeMounts:
    - name: pipelock-evidence
      mountPath: /var/lib/pipelock/evidence
    - name: pipelock-receipt-key
      # Do not mount this under /etc/pipelock; the chart already mounts the
      # Pipelock ConfigMap there.
      mountPath: /run/secrets/pipelock
      readOnly: true
```

Keep `requireReceipts: false` until you have confirmed receipts are being written. Turning it on makes allow-path receipt emission fail closed: if Pipelock cannot sign or write the receipt, the request is blocked before egress.

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
| `trusted_domains` | Allow internal services whose public DNS resolves to private IPs |
| `forward_proxy` | Outbound HTTPS tunnel controls and connection timeouts |
| `dlp` | Data loss prevention (scan env vars, built-in patterns) |
| `request_body_scanning` | Scan cleartext HTTP, reverse-proxy, and WebSocket request bodies; HTTPS bodies require TLS interception |
| `response_scanning` | Scan readable responses for prompt injection; HTTPS tunnel responses require TLS interception |
| `mcp_input_scanning` | Scan inbound MCP requests |
| `mcp_tool_scanning` | Validate tool calls, detect drift |
| `mcp_tool_policy` | Pre-execution rules, shell obfuscation, redirect profiles |
| `mcp_session_binding` | Pin tool inventory, detect manipulation |
| `tool_chain_detection` | Multi-step attack patterns |
| `websocket_proxy` | WebSocket frame scanning (disabled by default) |
| `health_watchdog` | Wedge-detection on subsystem heartbeats, returns 503 on stall (pipelock 2.4+) |
| `flight_recorder` | Signed action receipts and hash-chained evidence (inert until storage + signing key are mounted) |
| `logging` | Output format (json/text), verbosity |

For the Helm chart, most sections are configurable via `values.yaml`. For additional sections not covered by structured values (session profiling, data budgets, kill switch, sandbox, reverse proxy, adaptive enforcement, request policy, redaction), use the `extraConfig` escape hatch:

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

- Proxy variables are cooperative. Clients that don't honor them can connect directly unless the deployment enforces egress routing.
- The default examples don't configure TLS interception, so Pipelock can't scan encrypted HTTPS request or response bodies.
- Docker Compose has no egress network policies. The `/mcp` endpoint on port 3000 is still reachable directly (auth token required). For enforcement, use Kubernetes NetworkPolicies.
- Pipelock 3.4 scans reverse-proxy bodies that declare media types, but it doesn't inspect secrets embedded inside a valid image.
- Signed receipts prove traffic that traversed Pipelock. They do not prove traffic could not bypass Pipelock; pair them with NetworkPolicies, containment, or firewall rules for non-bypass claims.

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

### Receipts are not being written

Run:

```bash
docker compose -f compose.ai.yml exec pipelock /pipelock keys status --config /etc/pipelock/pipelock.yaml
docker compose -f compose.ai.yml exec pipelock /pipelock doctor --config /etc/pipelock/pipelock.yaml
```

The `receipt-signing` key must be present, readable by the Pipelock process, and valid. The `flight_recorder.dir` path must be writable.
