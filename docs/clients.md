# Sure Clients

Sure is centered on a Rails server. Every client connects to that server and
uses the same accounts, users, authentication rules, and financial data. A
client can be a browser, a native app, a mobile app, an automation script, or an
LLM agent using Sure's MCP endpoint.

Use this guide to choose the right entry point for a person, device, or
integration.

## Client overview

| Client | Best for | Status | Entry point |
| --- | --- | --- | --- |
| Web app | Full everyday use, administration, and self-hosted access from any modern browser. | Primary client | Run the Rails app and visit the server URL. For local development, use `bin/dev` and open `http://localhost:3000`. |
| macOS desktop app | People who want Sure in a native Mac window with system app chrome and deep-link handling. | Native shell around the web app | See [Sure Desktop](../desktop/README.md). |
| Mobile app | Basic mobile access on iOS and Android, currently focused on login and account balances. | Flutter companion app | See [Sure Mobile](../mobile/README.md). |
| LLM agents and assistants | Claude Desktop, GPT agents, local agents, or custom tools that need structured access to Sure data. | MCP endpoint for external AI clients | See [MCP Server for External AI Assistants](hosting/mcp.md). |
| Custom API clients | Scripts, services, importer experiments, dashboards, or other integrations. | HTTP API | See the OpenAPI spec at [docs/api/openapi.yaml](api/openapi.yaml) and endpoint guides such as [docs/api/transactions.md](api/transactions.md). |

## Web app

The web app is the complete Sure experience. It is the right default when a
person wants to use Sure directly, manage settings, connect providers, review
transactions, or work with features that may not yet be available in native
clients.

For self-hosting, start with the [Docker hosting guide](hosting/docker.md). For
local development, run the Rails app and visit the local server URL:

```sh
bin/dev
```

```text
http://localhost:3000
```

The web app also serves as the surface rendered by the macOS desktop app.

## macOS desktop app

The macOS desktop app is a Tauri 2 shell that renders the full Sure web app in a
native Mac window. On first launch, it asks for the Sure server URL, checks the
server health endpoint, and then loads the normal sign-in flow.

Use it when someone wants a desktop app experience without a separate desktop
data model. It uses the same server, authentication, MFA, and permissions as the
browser.

See [desktop/README.md](../desktop/README.md) for development, release, unsigned
install, deep link, and notarization notes.

## Mobile app

The mobile app is a Flutter companion app for iOS and Android. It connects to a
Sure server through the API and currently focuses on core mobile flows such as
authentication and viewing account balances.

Use it when someone needs phone access and the feature set they need is
available in the mobile client. For the full application surface, use the web
app.

See [mobile/README.md](../mobile/README.md) for setup and
[mobile/docs/TECHNICAL_GUIDE.md](../mobile/docs/TECHNICAL_GUIDE.md) for deeper
implementation notes.

## LLM agents and MCP clients

LLM agents are clients too. Sure exposes a Model Context Protocol endpoint for
external assistants and agent runtimes that need structured access to financial
data.

Use MCP when a person wants an assistant such as Claude Desktop, a GPT agent, or
a custom local agent to query Sure directly instead of copying data into a chat
window. MCP access is configured server-side with a bearer token and a specific
Sure user email.

Because this gives the assistant read access to that user's family data, treat
the MCP token like a production secret and only connect assistants and providers
the user trusts.

See [docs/hosting/mcp.md](hosting/mcp.md) for setup and protocol details.

## Custom API clients

Custom clients can call Sure's HTTP API directly. This is the right path for
scripts, services, import experiments, dashboards, and integrations that do not
need an MCP-compatible agent interface.

API requests can authenticate with a user-generated `X-Api-Key` header, or with
OAuth2 bearer tokens from Sure's Doorkeeper authorization server for registered
app clients.

Start with the OpenAPI spec at [docs/api/openapi.yaml](api/openapi.yaml) and
endpoint guides such as [docs/api/transactions.md](api/transactions.md).

## Choosing a client

- Start with the web app when a person needs the complete Sure experience.
- Use the macOS desktop app when they want the web app wrapped in a native Mac
  application.
- Use the mobile app for iOS or Android access to supported mobile flows.
- Use MCP for LLM agents and assistant runtimes.
- Use the HTTP API for custom software integrations.

All clients should connect to a Sure server the user controls or trusts. Native,
mobile, API, and MCP clients do not replace the server; they are different ways
to access it.
