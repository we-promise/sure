# fix(auth): block local account creation in pure SSO-only mode (#1430)

## Summary

In pure SSO-only mode — `AUTH_LOCAL_LOGIN_ENABLED=false` and
`AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED=false` — the login form is correctly hidden, but
**local account creation was still possible**. A user could click "Create account",
register a local email/password account, and use it once. After logging out they could
never sign in again (local login is disabled), leaving an orphaned, unusable account.

The login path was already gated by `AuthConfig.local_login_enabled?`, but the
registration path never received the equivalent guard.

Closes #1430.

## Root cause

`RegistrationsController` and the API `signup` action never consulted
`AuthConfig.local_login_enabled?`, and the auth layout rendered the "Create account"
link unconditionally. Only `Setting.onboarding_state` was checked, so SSO-only mode did
nothing to stop local signups.

## Fix

Gate every local-signup entry point on `AuthConfig.local_login_enabled?` (the same
helper the login page uses, matching the existing `password_features_enabled?`
semantics so the admin-override case still blocks signup):

- **`RegistrationsController`** — added `before_action :ensure_local_login_enabled`
  (runs first, halting before any user/invitation is built). Redirects to the login page
  with a flash message.
- **`Api::V1::AuthController#signup`** — added the same guard, returning
  `403 { "error": "Local account creation is disabled" }`. The SSO provisioning path
  (`sso_create_account`) is untouched.
- **`layouts/auth.html.erb`** — hid the "Create account" link and the mobile
  sign-in/sign-up toggle when local login is disabled.
- **Locale** — added `registrations.local_login_disabled`.

### Invitations

Invitation-based local signup is intentionally blocked too. The SSO callback already
accepts pending invitations (`store_pending_invitation_if_valid` /
`accept_pending_invitation_for`), so invited users join via SSO instead — which avoids
recreating the same orphaned-account problem.

## Changes

| File | Change |
| --- | --- |
| `app/controllers/registrations_controller.rb` | `ensure_local_login_enabled` guard (web) |
| `app/controllers/api/v1/auth_controller.rb` | `ensure_local_login_enabled` guard (API `signup`) |
| `app/views/layouts/auth.html.erb` | Hide "Create account" links when local login is disabled |
| `config/locales/views/registrations/en.yml` | New `registrations.local_login_disabled` string |
| `test/controllers/registrations_controller_test.rb` | Web + view regression tests |
| `test/controllers/api/v1/auth_controller_test.rb` | API `signup` regression test |

## Testing

New regression tests cover:

- Web `new` and `create` are blocked (redirect to login) when local login is disabled.
- Invitation-based `create` is also blocked.
- The login page no longer renders the "Create account" link.
- API `signup` returns `403` and creates no user.

Existing signup tests continue to pass (local login defaults to enabled).

Run locally:

```bash
bin/rails test test/controllers/registrations_controller_test.rb \
  test/controllers/api/v1/auth_controller_test.rb
bin/rubocop -f github -a app/controllers/registrations_controller.rb \
  app/controllers/api/v1/auth_controller.rb
bundle exec erb_lint app/views/layouts/auth.html.erb
```

## Behavior

| Mode | Local login form | "Create account" link | Local signup (web/API) |
| --- | --- | --- | --- |
| Default (local login enabled) | shown | shown | allowed |
| Admin override only | hidden (super-admin backend login) | hidden | blocked |
| Pure SSO-only | hidden | hidden | blocked |

🤖 Generated with [Claude Code](https://claude.com/claude-code)
