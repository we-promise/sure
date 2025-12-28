# Configuring OpenID Connect and SSO providers

This guide shows how to enable OpenID Connect (OIDC) and other single sign-on (SSO) providers for Sure using Google, GitHub, or another OIDC‑compatible identity provider (e.g. Keycloak, Authentik).

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
