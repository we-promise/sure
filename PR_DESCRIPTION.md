## Summary

Adds support for self-signed SSL certificates in self-hosted environments, fixing connection failures when using internal CAs for OIDC/SSO providers, self-hosted LLMs, and other external services.

## Problem

Users running the application in home labs or private networks with self-signed certificates receive SSL errors:

```
SSL_connect returned=1 errno=0 state=error: certificate verify failed (self-signed certificate in certificate chain)
```

## Solution

Introduces three environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `SSL_CA_FILE` | Path to custom CA certificate (PEM format) | Not set |
| `SSL_VERIFY` | Enable/disable SSL verification | `true` |
| `SSL_DEBUG` | Enable verbose SSL logging | `false` |

### Key Features

- **Combined CA Bundle**: Automatically creates a combined CA bundle (system CAs + custom CA) to ensure both public services and self-signed internal services work
- **Global SSL Configuration**: Sets `SSL_CERT_FILE` for Ruby-wide SSL support (including OIDC discovery requests)
- **Certificate Validation**: Validates PEM format and certificate parsing before use
- **Error Handling**: Provides clear error messages with resolution hints for SSL failures

## Usage

```yaml
# docker-compose.yml
services:
  app:
    environment:
      SSL_CA_FILE: /certs/my-ca.crt
    volumes:
      - ./my-ca.crt:/certs/my-ca.crt:ro
```

## Changes

- **New** `config/initializers/00_ssl.rb` - Centralized SSL configuration (prefixed to load before OmniAuth)
- **New** `app/models/concerns/ssl_configurable.rb` - Reusable SSL helper module with error handling
- **Updated** all HTTP clients (HTTParty, Faraday, Net::HTTP) to use SSL config
- **Updated** OmniAuth OIDC configuration to pass SSL options
- **Updated** Langfuse client with proper CRL error handling for OpenSSL 3.x
- **Added** documentation in `.env.local.example` and `docs/hosting/oidc.md`
