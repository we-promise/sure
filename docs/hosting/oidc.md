# Configuring OpenID Connect, SAML, and SSO Providers

This guide shows how to enable OpenID Connect (OIDC), SAML 2.0, and other single sign-on (SSO) providers for Sure using Google, GitHub, or another identity provider (e.g. Keycloak, Authentik, Okta, Azure AD).

It also documents the new `config/auth.yml` and environment variables that control:

- Whether local email/password login is enabled
- Whether an emergency super‑admin override is allowed
- How JIT SSO account creation behaves (create vs link‑only, allowed domains)
- Which SSO providers appear as buttons on the login page

---

## 1. Create an OIDC / OAuth client in your IdP

For Google, follow the standard OAuth2 client setup:

1. Visit <https://console.cloud.google.com> and sign in.
2. Create a new project or select an existing one.
3. Configure the OAuth consent screen under **APIs & Services > OAuth consent screen**.
4. Go to **APIs & Services > Credentials** and click **Create Credentials > OAuth client ID**.
5. Select **Web application** as the application type.
6. Add an authorized redirect URI. For local development:

   ```
   http://localhost:3000/auth/openid_connect/callback
   ```

   For production, use your domain:

   ```
   https://yourdomain.com/auth/openid_connect/callback
   ```

7. After creating the credentials, copy the **Client ID** and **Client Secret**.

For other OIDC providers (e.g. Keycloak), create a client with a redirect URI of:

```
https://yourdomain.com/auth/openid_connect/callback
```

and ensure that the `openid`, `email`, and `profile` scopes are available.

---

## 2. Configure Sure: OIDC core settings

Set the following environment variables in your deployment (e.g. `.env`, `docker-compose`, or hosting platform):

```bash
OIDC_ISSUER="https://accounts.google.com"              # or your Keycloak/AuthentiK issuer URL
OIDC_CLIENT_ID="your-oidc-client-id"
OIDC_CLIENT_SECRET="your-oidc-client-secret"
OIDC_REDIRECT_URI="https://yourdomain.com/auth/openid_connect/callback"
```

Restart the application after saving the variables.

When OIDC is correctly configured, users can sign in from the login page using the **Sign in with OpenID Connect** button (label can be customized, see below). The IdP must report the user's email as verified, and it must match an existing user or be allowed for JIT creation.

---

## 3. Auth configuration (`config/auth.yml`)

Authentication behavior is driven by `config/auth.yml`, which can be overridden via environment variables.

### 3.1 Structure

```yaml
default: &default
  local_login:
    enabled: <%= ENV.fetch("AUTH_LOCAL_LOGIN_ENABLED", "true") == "true" %>
    admin_override_enabled: <%= ENV.fetch("AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED", "false") == "true" %>

  jit:
    mode: <%= ENV.fetch("AUTH_JIT_MODE", "create_and_link") %>
    allowed_oidc_domains: <%= ENV.fetch("ALLOWED_OIDC_DOMAINS", "") %>

  providers:
    - id: "oidc"
      strategy: "openid_connect"
      name: "openid_connect"
      label: <%= ENV.fetch("OIDC_BUTTON_LABEL", "Sign in with OpenID Connect") %>
      icon:  <%= ENV.fetch("OIDC_BUTTON_ICON", "key") %>

    - id: "google"
      strategy: "google_oauth2"
      name: "google_oauth2"
      label: <%= ENV.fetch("GOOGLE_BUTTON_LABEL", "Sign in with Google") %>
      icon:  <%= ENV.fetch("GOOGLE_BUTTON_ICON", "google") %>

    - id: "github"
      strategy: "github"
      name: "github"
      label: <%= ENV.fetch("GITHUB_BUTTON_LABEL", "Sign in with GitHub") %>
      icon:  <%= ENV.fetch("GITHUB_BUTTON_ICON", "github") %>

development:
  <<: *default

test:
  <<: *default

production:
  <<: *default
```

### 3.2 Local login flags

- `AUTH_LOCAL_LOGIN_ENABLED` (default: `true`)
  - When `true`, the login page shows the email/password form and "Forgot password" link.
  - When `false`, local login is disabled for all users unless the admin override flag is enabled.
  - When `false`, password reset via Sure is also disabled (users must reset via the IdP).

- `AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED` (default: `false`)
  - When `true` and `AUTH_LOCAL_LOGIN_ENABLED=false`, super‑admin users can still log in with local passwords.
  - Regular users remain SSO‑only.
  - The login form is visible with a note: "Local login is restricted to administrators."
  - Successful override logins are logged in the Rails logs.

### 3.3 JIT user creation

- `AUTH_JIT_MODE` (default: `create_and_link`)
  - `create_and_link`: the current behavior.
    - If the SSO identity is new and the email does not match an existing user, Sure will offer to create a new account (subject to domain checks below).
  - `link_only`: stricter behavior.
    - New SSO identities can only be linked to existing users; JIT account creation is disabled.
    - Users without an existing account are sent back to the login page with an explanatory message.

- `ALLOWED_OIDC_DOMAINS`
  - Optional comma‑separated list of domains (e.g. `example.com,corp.com`).
  - When **empty**, JIT SSO account creation is allowed for any verified email.
  - When **set**, JIT SSO account creation is only allowed if the email domain is in this list.
  - Applies uniformly to all SSO providers (OIDC, Google, GitHub, etc.) that supply an email.

### 3.4 Providers and buttons

Each provider entry in `providers` configures an SSO button on the login page:

- `id`: a short identifier used in docs and conditionals.
- `strategy`: the OmniAuth strategy (`openid_connect`, `google_oauth2`, `github`, ...).
- `name`: the OmniAuth provider name, which determines the `/auth/:provider` path.
- `label`: button text shown to users.
- `icon`: optional icon name passed to the Sure `icon` helper (e.g. `key`, `google`, `github`).

Special behavior:

- Providers with `id: "google"` or `strategy: "google_oauth2"` render a Google‑branded sign‑in button.
- Other providers (e.g. OIDC/Keycloak, GitHub) render a generic styled button with the configured label and icon.

#### Enabling Google sign‑in (local dev / self‑hosted)

The Google button is only shown when the Google provider is actually registered by OmniAuth at boot.

To enable Google:

1. Ensure the Google provider exists in `config/auth.yml` under `providers:` with `strategy: "google_oauth2"`.
2. Set these environment variables (for example in `.env.local`, Docker Compose, or your process manager):

   - `GOOGLE_OAUTH_CLIENT_ID`
   - `GOOGLE_OAUTH_CLIENT_SECRET`

   If either is missing, Sure will skip registering the Google provider and the Google button will not appear on the login page.

3. In your Google Cloud OAuth client configuration, add an authorized redirect URI that matches the host you use in dev.

   Common local values:

   - `http://localhost:3000/auth/google_oauth2/callback`
   - `http://127.0.0.1:3000/auth/google_oauth2/callback`

   If you customize the provider `name` in `config/auth.yml`, the callback path changes accordingly:

   - `http://localhost:3000/auth/<provider_name>/callback`

### 3.5 Bootstrapping the first super‑admin

The first `super_admin` must be set via Rails console. Access the console in your container/pod or directly on the server:

```bash
bin/rails console
```

Then promote a user:

```ruby
# Set super_admin role
User.find_by(email: "admin@example.com").update!(role: :super_admin)

# Verify
User.find_by(email: "admin@example.com").role  # => "super_admin"
```

Once set, super‑admins can promote other users via the web UI at `/admin/users`.

---

## 4. Example configurations

### 4.1 Default hybrid (local + SSO)

This is effectively the default configuration:

```bash
AUTH_LOCAL_LOGIN_ENABLED=true
AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED=false
AUTH_JIT_MODE=create_and_link
ALLOWED_OIDC_DOMAINS=""   # or unset
```

Behavior:

- Users can sign in with email/password or via any configured SSO providers.
- JIT SSO account creation is allowed for all verified email domains.

### 4.2 Pure SSO‑only

Disable local login entirely:

```bash
AUTH_LOCAL_LOGIN_ENABLED=false
AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED=false
```

Behavior:

- Email/password form and "Forgot password" link are hidden.
- `POST /sessions` with local credentials is blocked and redirected with a message.
- Password reset routes are disabled (redirect to the login page with an IdP message).

### 4.3 SSO‑only with emergency admin override

Allow only super‑admin users to log in locally during IdP outages:

```bash
AUTH_LOCAL_LOGIN_ENABLED=false
AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED=true
```

Behavior:

- Login page shows the email/password form with a note that local login is restricted to administrators.
- Super‑admins can log in with their local password; non‑super‑admins are blocked.
- Password reset remains disabled for everyone.
- Successful override logins are logged.

### 4.4 Link‑only JIT + restricted domains

Lock down JIT creation to specific domains and require existing users otherwise:

```bash
AUTH_JIT_MODE=link_only
ALLOWED_OIDC_DOMAINS="example.com,yourcorp.com"
```

Behavior:

- SSO sign‑ins with emails under `example.com` or `yourcorp.com` can be linked to existing Sure users.
- New account creation via SSO is disabled; users without accounts see appropriate messaging and must contact an admin.
- SSO sign‑ins from any other domain cannot JIT‑create accounts.

---

With these settings, you can run Sure in:

- Traditional local login mode
- Hybrid local + SSO mode
- Strict SSO‑only mode with optional super‑admin escape hatch
- Domain‑restricted and link‑only enterprise SSO modes

Use the combination that best fits your self‑hosted environment and security posture.

---

## 5. Multiple OIDC Providers

Sure supports configuring multiple OIDC providers simultaneously, allowing users to choose between different identity providers (e.g., Keycloak, Authentik, Okta) on the login page.

### 5.1 YAML-based multi-provider configuration

To add multiple OIDC providers in `config/auth.yml`, add additional provider entries with unique names:

```yaml
providers:
  # First OIDC provider (e.g., Keycloak)
  - id: "keycloak"
    strategy: "openid_connect"
    name: "keycloak"
    label: "Sign in with Keycloak"
    icon: "key"
    issuer: <%= ENV["OIDC_KEYCLOAK_ISSUER"] %>
    client_id: <%= ENV["OIDC_KEYCLOAK_CLIENT_ID"] %>
    client_secret: <%= ENV["OIDC_KEYCLOAK_CLIENT_SECRET"] %>
    redirect_uri: <%= ENV["OIDC_KEYCLOAK_REDIRECT_URI"] %>

  # Second OIDC provider (e.g., Authentik)
  - id: "authentik"
    strategy: "openid_connect"
    name: "authentik"
    label: "Sign in with Authentik"
    icon: "shield"
    issuer: <%= ENV["OIDC_AUTHENTIK_ISSUER"] %>
    client_id: <%= ENV["OIDC_AUTHENTIK_CLIENT_ID"] %>
    client_secret: <%= ENV["OIDC_AUTHENTIK_CLIENT_SECRET"] %>
    redirect_uri: <%= ENV["OIDC_AUTHENTIK_REDIRECT_URI"] %>
```

Set the corresponding environment variables:

```bash
# Keycloak provider
OIDC_KEYCLOAK_ISSUER="https://keycloak.example.com/realms/myrealm"
OIDC_KEYCLOAK_CLIENT_ID="sure-client"
OIDC_KEYCLOAK_CLIENT_SECRET="your-keycloak-secret"
OIDC_KEYCLOAK_REDIRECT_URI="https://yourdomain.com/auth/keycloak/callback"

# Authentik provider
OIDC_AUTHENTIK_ISSUER="https://authentik.example.com/application/o/sure/"
OIDC_AUTHENTIK_CLIENT_ID="sure-authentik-client"
OIDC_AUTHENTIK_CLIENT_SECRET="your-authentik-secret"
OIDC_AUTHENTIK_REDIRECT_URI="https://yourdomain.com/auth/authentik/callback"
```

**Important:** Each provider must have a unique `name` field, which determines the callback URL path (`/auth/<name>/callback`).

---

## 6. Database-Backed Provider Management

For more dynamic provider management, Sure supports storing SSO provider configurations in the database with a web-based admin interface.

### 6.1 Enabling database providers

Set the feature flag to load providers from the database instead of YAML:

```bash
AUTH_PROVIDERS_SOURCE=db
```

When enabled:
- Providers are loaded from the `sso_providers` database table
- Changes take effect immediately (no server restart required)
- Providers can be managed through the admin UI at `/admin/sso_providers`

When disabled (default):
- Providers are loaded from `config/auth.yml`
- Changes require a server restart

### 6.2 Admin UI for SSO providers

Super-admin users can manage SSO providers through the web interface:

1. Navigate to `/admin/sso_providers`
2. View all configured providers (enabled/disabled status)
3. Add new providers with the "Add Provider" button
4. Edit existing providers (credentials, labels, icons)
5. Enable/disable providers with the toggle button
6. Delete providers (with confirmation)

**Security notes:**
- Only users with `super_admin` role can access the admin interface
- All provider changes are logged with user ID and timestamp
- Client secrets are encrypted in the database using Rails 7.2 encryption
- Admin endpoints are rate-limited (10 requests/minute per IP)

### 6.3 Seeding providers from YAML to database

To migrate your existing YAML configuration to the database:

```bash
# Dry run (preview changes without saving)
DRY_RUN=true rails sso_providers:seed

# Apply changes
rails sso_providers:seed
```

The seeding task:
- Reads providers from `config/auth.yml`
- Creates or updates database records (idempotent)
- Preserves existing client secrets if not provided in YAML
- Provides detailed output (created/updated/skipped/errors)

To list all providers in the database:

```bash
rails sso_providers:list
```

### 6.4 Migration workflow

Recommended steps to migrate from YAML to database-backed providers:

1. **Backup your configuration:**
   ```bash
   cp config/auth.yml config/auth.yml.backup
   ```

2. **Run migrations:**
   ```bash
   rails db:migrate
   ```

3. **Seed providers from YAML (dry run first):**
   ```bash
   DRY_RUN=true rails sso_providers:seed
   ```

4. **Review the output, then apply:**
   ```bash
   rails sso_providers:seed
   ```

5. **Enable database provider source:**
   ```bash
   # Add to .env or environment
   AUTH_PROVIDERS_SOURCE=db
   ```

6. **Restart the application:**
   ```bash
   # Docker Compose
   docker-compose restart app

   # Or your process manager
   systemctl restart sure
   ```

7. **Verify providers are loaded:**
   - Check logs for `[ProviderLoader] Loaded N provider(s) from database`
   - Visit `/admin/sso_providers` to manage providers

### 6.5 Rollback to YAML

To switch back to YAML-based configuration:

1. Remove or set `AUTH_PROVIDERS_SOURCE=yaml`
2. Restart the application
3. Providers will be loaded from `config/auth.yml`

### 6.6 JIT provisioning settings

Each provider has a **Default Role** field (defaults to `member`) that sets the role for JIT-created users.

**Role mapping from IdP groups:**

Expand **"Role Mapping"** in the admin UI to map IdP group names to Sure roles. Enter comma-separated group names for each role:

- **Super Admin Groups**: `Platform-Admins, IdP-Superusers`
- **Admin Groups**: `Team-Leads, Managers`
- **Member Groups**: `Everyone` or leave blank

Mapping is case-sensitive and matches exact group claim values from the IdP. When a user belongs to multiple mapped groups, the highest role wins (`super_admin` > `admin` > `member`). If no groups match, the Default Role is used.

---

## 7. Troubleshooting

### Provider not appearing on login page

- **YAML mode:** Check that required environment variables are set (e.g., `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`)
- **DB mode:** Verify provider is enabled in `/admin/sso_providers`
- Check application logs for provider loading messages
- Verify `AUTH_PROVIDERS_SOURCE` is set correctly

### Discovery endpoint validation fails

When adding an OIDC provider, Sure validates the `.well-known/openid-configuration` endpoint:

- Ensure the issuer URL is correct and accessible
- Check firewall rules allow outbound HTTPS to the issuer
- Verify the issuer returns valid JSON with an `issuer` field
- For self-signed certificates, configure SSL verification (see below)

### Self-signed certificate support

If your identity provider uses self-signed certificates or certificates from an internal CA, configure the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `SSL_CA_FILE` | Path to custom CA certificate (PEM format) | Not set |
| `SSL_VERIFY` | Enable/disable SSL verification | `true` |
| `SSL_DEBUG` | Enable verbose SSL logging | `false` |

**Option 1: Custom CA certificate (recommended)**

Mount your CA certificate into the container and set `SSL_CA_FILE`:

```yaml
# docker-compose.yml
services:
  app:
    environment:
      SSL_CA_FILE: /certs/my-ca.crt
    volumes:
      - ./my-ca.crt:/certs/my-ca.crt:ro
```

The certificate file must:
- Be in PEM format (starts with `-----BEGIN CERTIFICATE-----`)
- Be readable by the application
- Be the CA certificate that signed your server's SSL certificate

**Option 2: Disable SSL verification (NOT recommended for production)**

For testing only, you can disable SSL verification:

```bash
SSL_VERIFY=false
```

**Warning:** Disabling SSL verification removes protection against man-in-the-middle attacks. Only use this for development or testing environments.

**Troubleshooting SSL issues**

Enable debug logging to diagnose SSL certificate problems:

```bash
SSL_DEBUG=true
```

This will log detailed information about SSL connections, including:
- Which CA file is being used
- SSL verification mode
- Detailed error messages with resolution hints

Common error messages and solutions:

| Error | Solution |
|-------|----------|
| `self-signed certificate` | Set `SSL_CA_FILE` to your CA certificate |
| `certificate verify failed` | Ensure `SSL_CA_FILE` points to the correct CA |
| `certificate has expired` | Renew the server's SSL certificate |
| `unknown CA` | Add the issuing CA to `SSL_CA_FILE` |

### Rate limiting errors (429)

Admin endpoints are rate-limited to 10 requests per minute per IP:

- Wait 60 seconds before retrying
- If legitimate traffic is being blocked, adjust limits in `config/initializers/rack_attack.rb`

### Callback URL mismatch

Each provider requires a callback URL configured in your identity provider:

- **Format:** `https://yourdomain.com/auth/<provider_name>/callback`
- **Example:** For a provider with `name: "keycloak"`, use `https://yourdomain.com/auth/keycloak/callback`
- The callback URL is shown in the admin UI when editing a provider (with copy button)

---

## 8. Security Considerations

### Encryption

- Client secrets are encrypted at rest using Rails 7.2 ActiveRecord Encryption
- Encryption keys are derived from `SECRET_KEY_BASE` by default
- For additional security, set custom encryption keys (see `.env` for `ACTIVE_RECORD_ENCRYPTION_*` variables)

### Issuer validation

- OIDC identities store the issuer claim from the ID token
- On subsequent logins, Sure verifies the issuer matches the configured provider
- This prevents issuer impersonation attacks

### Admin access

- SSO provider management requires `super_admin` role
- Regular `admin` users (family admins) cannot access `/admin/sso_providers`
- All provider changes are logged with user ID

### Rate limiting

- Admin endpoints: 10 requests/minute per IP
- OAuth token endpoint: 10 requests/minute per IP
- Failed login attempts should be monitored separately

---

## 9. SAML 2.0 Support

Sure supports SAML 2.0 via database-backed providers. Select **"SAML 2.0"** as the strategy when adding a provider at `/admin/sso_providers`.

Configure with either:
- **IdP Metadata URL** (recommended) - auto-fetches configuration
- **Manual config** - IdP SSO URL + certificate

In your IdP, set:
- **ACS URL**: `https://yourdomain.com/auth/<provider_name>/callback`
- **Entity ID**: `https://yourdomain.com` (your `APP_URL`)
- **Name ID**: Email Address

---

## 10. User Administration

Super‑admins can manage user roles at `/admin/users`.

Roles: `member` (standard), `admin` (family admin), `super_admin` (platform admin).

Note: Super‑admins cannot change their own role.

---

## 11. Audit Logging

SSO events are logged to `sso_audit_logs`: `login`, `login_failed`, `logout`, `logout_idp` (federated logout), `link`, `unlink`, `jit_account_created`.

Query via console:

```ruby
SsoAuditLog.by_event("login").recent.limit(50)
SsoAuditLog.by_event("login_failed").where("created_at > ?", 24.hours.ago)
```

---

## 12. User SSO Identity Management

Users manage linked SSO identities at **Settings > Security**.

SSO-only users (no password) cannot unlink their last identity.

---

For additional help, see the main [hosting documentation](../README.md) or open an issue on GitHub.
