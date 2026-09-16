# Native connection configuration

Shared connection settings now have a browser path and a family-scoped command.
Implementation and behavioral tests are written but unrun. This does not activate
any provider, perform a token exchange, or establish migration acceptance.

`ProviderConnection::Configuration` owns settings publication. Its editor returns
a signed, expiring form bound to the original connection, actor, family, provider,
row version, credential revision, writer epoch, and migration control/mapping.
Submission takes the shared credential session lock, then short NOWAIT row locks.
It rechecks the current active administrator, exact native ownership and original
form before applying changes. A copied connection cannot be treated as newly
native when its migration control is missing. Retired legacy data still retains
its native connection and original mapping.

The existing `CredentialStore` now exposes its lock separately from a refresh
session. Opening an editor does not create a refresh session or change an uncertain
exchange. Administrative replacement and native refresh use the same PostgreSQL
session lock. Nested credential operations refuse. Unknown acquisition/release
outcomes disconnect the session, and cleanup cannot replace the original error.
No network request runs inside the configuration transaction.

Pending provider Syncs or any retained lease block an update, including an expired
lease that still needs recovery. Settings do not cancel jobs, erase cursors, adopt
captured pages or schedule a replacement Sync. The existing recovery flow must
settle interrupted work first. Successful changes advance the writer epoch and
row version; changed credentials also advance their revision. A no-op preserves
all three. A prior form or captured credential grant cannot adopt replacement
credentials.

## Explicit editable credentials

An adapter's `editable_connection_credentials` declaration opts in reviewed static
credential fields. It defaults to an empty list. Each declared field must already
be a secret string/text field in the adapter definition, scoped to the connection.
The reviewed declarations are Up's `access_token`, Mercury's and Brex's `token`,
and Akahu's `app_token` and `user_token`. Adapter readiness remains a separate gate.

The shared editor offers name and history start date, plus only those declared
secrets. Secret inputs are always empty; blank values preserve existing secrets.
A different explicitly supplied static token may restore `requires_update` to
`good`. A name change or resubmitting the same token cannot claim reauthorization.
An unfinished credential exchange or explicit provider authorization prevents
static token replacement, retaining that provider's dedicated authorization flow.
Mercury's and Brex's endpoints remain immutable here: changing credential destination needs
a separate reviewed transition.

Definition fields alone do not authorize editing. Rotating refresh tokens,
session cookies, deployment credentials and grant renewals require their own
replacement semantics and receipts. This command cannot reset their uncertain
state or infer approval from a changed revision.

## Browser integration and preserved evidence

The provider settings page lists native-owned connections through safe display
headers, including connections whose legacy item has been retired. Migrated Up,
Mercury, Brex and Akahu settings use the shared editor; their legacy forms are hidden in
that page. Existing edit URLs redirect to the shared connection. Native-only
families retain the existing Sync all action. The runtime readiness allowlist
still controls which native connections are offered.

The controller uses `Current.family` and `Current.user`, validates the command
boundary, and reports fixed localized errors. It never renders submitted secrets
or exception messages. Diagnostic metadata identifies the connection and error
class without credential values. The form uses existing DS components and Rails
fields; no styles or API v1 endpoints are added.

Updates affect the shared connection only. Original legacy credentials, copied
archives, migration mappings and financial identities remain unchanged. This
preserves audit evidence rather than making the old copy appear to contain a
later replacement token.

The [model tests](../../test/models/provider_connection/configuration_test.rb)
cover actual persistence, encryption, stale/foreign forms, permission changes,
pending work, missing controls, preserved migration data and competing credential
sessions. [Lock fault tests](../../test/models/provider/account_data/credential_lock_test.rb)
cover acquisition/release uncertainty and interruption. The
[controller tests](../../test/controllers/provider_connections_controller_test.rb)
cover routes, rendering, family/admin boundaries, safe errors and settings links.
They are authored, not executed. [Native account setup](provider-native-account-setup.md)
now has a separate signed command and browser flow with explicit provider and
retained-history gates. Native disconnection, retirement/rollback commands and
remaining providers' reauthorization flows remain separate migration requirements.
