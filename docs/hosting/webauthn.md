# WebAuthn MFA Configuration

Sure supports passkeys, Touch ID, Windows Hello, and hardware security keys as MFA credentials. WebAuthn credentials are bound to the relying party ID used when they are registered, so production deployments should pin these values explicitly instead of deriving them from incoming request headers.

Set these environment variables for self-hosted deployments:

```bash
WEBAUTHN_RP_ID=example.com
WEBAUTHN_ALLOWED_ORIGINS=https://sure.example.com
```

`WEBAUTHN_RP_ID` is usually the registrable domain, such as `example.com`, not a full URL and not a hostname with a port. This lets credentials work across subdomains when the browser permits it.

`WEBAUTHN_ALLOWED_ORIGINS` is a comma-separated list of full origins where users access Sure, including scheme and host. Examples:

```bash
WEBAUTHN_ALLOWED_ORIGINS=https://sure.example.com,https://app.example.com
```

For local development, use:

```bash
WEBAUTHN_RP_ID=localhost
WEBAUTHN_ALLOWED_ORIGINS=http://localhost:3000
```

Changing `WEBAUTHN_RP_ID` after users register credentials can make existing passkeys and security keys unavailable. Keep the value stable across reverse proxy, domain, and hostname changes.
