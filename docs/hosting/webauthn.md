# WebAuthn Configuration

Sure supports passkeys, Touch ID, Windows Hello, and hardware security keys, both as a second factor and for passwordless sign-in. WebAuthn credentials are bound to the relying party ID used when they are registered, so production deployments should pin these values explicitly instead of deriving them from incoming request headers.

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

## Passwordless sign-in

A registered passkey can sign a user in directly from the login page, without a password and without the TOTP step. This is enabled by default:

```bash
AUTH_PASSKEY_LOGIN_ENABLED=true
```

Set it to `false` to keep passkeys as a second factor only.

### Why skipping the password is not a downgrade

The passwordless ceremony always requests `userVerification: "required"`, so the authenticator must confirm the person as well as the device — a biometric, a device PIN, or a security key PIN. That makes a lone passkey two independent factors (possession plus inherence or knowledge), which is the same bar as the password plus TOTP flow it replaces. An authenticator that can only confirm presence, such as a bare touch, is rejected on this path and still works as a second factor.

Sign-in is "usernameless": no email is submitted, because the browser returns the account handle along with the assertion. Nothing on this path can be probed to discover whether an account exists.

### Requirements

- The passkey must be **discoverable** (also called a resident key). Registration asks for one with `residentKey: "preferred"`. Password managers and platform authenticators — Proton Pass, iCloud Keychain, 1Password, Bitwarden, Windows Hello — store discoverable credentials by default. A hardware security key with no free resident-key slots still registers, but only as a second factor, and will not appear in the passkey picker.
- Users must enable two-factor authentication before they can register a passkey. Disabling 2FA removes every registered passkey, which also removes passwordless sign-in for that user.
- Passkey sign-in follows the same policy as local login. When `AUTH_LOCAL_LOGIN_ENABLED=false`, only super admins with `AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED=true` may use it.

### Upgrading an instance that already has passkeys

Passwordless sign-in is on by default, and it applies to passkeys that were
registered before this feature existed. A passkey a user added purely as a
second factor can, after the upgrade, sign that user in on its own.

This applies to a credential only if the authenticator that holds it made it
discoverable. Registration asks with `residentKey: "preferred"`, which an
authenticator is free to decline, and nothing in the database records what it
decided — so Sure cannot tell you in advance which existing credentials are
affected. In practice password managers and platform authenticators (Proton
Pass, iCloud Keychain, 1Password, Bitwarden, Windows Hello) store discoverable
credentials by default, so theirs generally are; a credential an authenticator
stored non-discoverably, such as one on a hardware key with no free resident-key
slot, stays second-factor only. Nothing needs to be re-registered either way.

The opt-out is instance-wide. There is no per-user or per-credential setting: to
keep passkeys as a second factor for everyone, set
`AUTH_PASSKEY_LOGIN_ENABLED=false` before upgrading. A single user can only opt
out by removing the credential.

This is not a reduction in security — the passwordless ceremony requires user
verification, so the passkey alone is still two factors, as described above. It
is a change in what an already-registered credential can do, and users who chose
a passkey specifically as a *second* factor have not consented to it signing
them in alone.

### Browser autofill

When the browser supports conditional mediation, saved passkeys are offered from the email field's autofill menu, before any button is clicked. Browsers without it fall back to the "Sign in with a passkey" button, which works the same way.
