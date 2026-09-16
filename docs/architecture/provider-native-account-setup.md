# Native account setup

`ProviderConnection::AccountSetup` and its nested browser screen connect a
discovered `ExternalAccount` to a new or existing financial `Account`. The code
and behavioral tests are written but unrun. This does not activate a provider or
establish migration acceptance. Up declares account setup for Depository and
Loan; Mercury declares Depository, Brex declares Depository and CreditCard, and
Akahu declares Depository, CreditCard, Loan and Investment. Mercury, Brex and Akahu
still have `native_ready? == false`. Other adapters default to no setup types.

## Admission and browser flow

The browser uses `Current.family` and `Current.user`, requires an administrator,
and exposes setup links only for a ready adapter with declared setup types. The
command independently checks a fresh active administrator, a good connection,
and exact native migration control and connection mapping through
`ProviderConnection::Management`. Missing copied provenance cannot become a new
native connection. Short NOWAIT locks refuse competing work.

The catalog lists active, unlinked discovered accounts, 50 per page, and at most
200 manageable existing-account choices. Selecting a source and optional existing
target produces a signed 30-minute confirmation. The signature binds the actor,
family, connection revisions, migration ownership, source fingerprint, exact
target, its links and policies, and the declared account types/resources and
resolved creation defaults. Final
submission derives its mode and source/target from that signature.

New accounts require an explicit name, declared account type, supported currency,
and decimal balance. The balance field starts empty; neither zero nor a raw
provider liability balance is supplied automatically. The existing account
constructor creates the financial account and opening anchor. Existing-account
confirmation submits only the token and preserves the account's financial fields.
The target must be visible, owned or shared with full control, of a supported type,
and compatible with the source currency.

Adapters may provide pure `account_setup_defaults` using frozen nonsecret source
data. The command accepts only a valid subtype and an explicit decimal cash
balance, and includes the resolved values in the signed selection. Akahu uses
this for subtype suggestions and Investment cash zero. Defaults affect only new
accounts; they cannot replace the user's entered balance, currency, name or owner.

Provider leases, unfinished generations or incomplete provider Syncs block a new
setup. Incomplete target-account Syncs also block linking. Existing links must be
native sources from different providers, with no Plaid/SimpleFIN direct link, and
the resulting account cannot exceed 32 links. A secondary connection requires
complete current source policies for its resources; those policies remain
authoritative. This is observation collection, not an automatic source switch or
merge of existing financial histories. A first source receives the declared
resource policies.

## Evidence, commit and retry

The source must have no previous financial binding or evidence requiring an
explicit relinking decision. Copied Up, Mercury, Brex and Akahu sources require verified
original nil account bindings and an empty retained transaction cache. Setup
keeps those signed archives, mapping identities and legacy rows unchanged; it
does not rewrite an old nil binding to look historically linked.

Eligible native observations collected before setup use the existing bounded
[retained transaction publisher](retained-transaction-publication.md) in the same transaction. It verifies the
original applied captures and unbound identities, refuses financial collisions,
and retains explicit removals/pending evidence. It does not invent history
coverage or advance provider cursors. Unsupported retained capture semantics
refuse setup rather than omit history.

The new link, policies when needed, retained publication and one pending provider
Sync commit atomically. That Sync stores a setup receipt with token/value digests
and original account/link/policy identities. Dispatch happens after the management
locks and transaction are released. A queue failure therefore leaves the committed
result available for a retry with the same unexpired token and values. Replays
recheck current ownership and reuse the original Sync; only an uncancelled pending
Sync is enqueued. This is not a general recovery screen for expired selections or
interrupted jobs.

Refresh queues discovery without provider HTTP in the controller or command. It
may reuse one uncancelled pending provider Sync; active work still refuses.
Responses and best-effort diagnostics contain fixed localized errors and safe
identifiers, never submitted tokens, credentials or exception text.

## Remaining acceptance

The browser and management layer do not require a live legacy item to route to a
native connection. Creating copied source policies can resolve removed legacy
owners through [captured ownership witnesses](provider-retained-owners.md),
provided the original verified archive and retired control still agree. Missing
rows without those witnesses refuse setup. The reviewed retirement command now
composes those witnesses with source and logo disposition for Up/Mercury/Brex/Akahu;
their old setup member URLs redirect to this screen without replaying old form
parameters. Expanding retirement, native disconnect, authority switching and other
providers' retained-history contracts remain separate work.

The [model tests](../../test/models/provider_connection/account_setup_test.rb)
cover actual account/link persistence, source selection, copied evidence and retry.
The [controller tests](../../test/controllers/provider_connections/account_setups_controller_test.rb)
cover routes, signed confirmation, explicit values, tenancy, safe errors and
settings links. All tests remain unrun because Ruby/Bundler is unavailable. See
[native configuration](provider-native-configuration.md) and the
[multi-source architecture](multi-source-ingestion.md) for adjacent boundaries.
