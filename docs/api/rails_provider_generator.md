# Account data provider generator

The account-data generator creates an integration package over a shared normalization
contract. It replaces the old generator that copied item/account tables, processing
and sync classes, controllers, jobs and views and patched shared application files.

The [architecture and rollout plan](../architecture/bank-data-providers.md) describes
shared persistence, synchronization and provider cutover gates. **The generator does
not activate an integration or migrate existing data.**
Generated packages are drafts and fail explicitly until their transport and
normalization are implemented and their runtime acceptance checks pass.
The [migration matrix](../architecture/bank-data-provider-migration-matrix.md)
covers every current bank, brokerage and crypto account integration.

## Usage

```sh
bin/rails generate provider:account_data acme_bank api_key:text:secret \
  base_url:string:default=https://api.example.test --type=banking

bin/rails generate provider:account_data acme_broker token:text:secret --type=investment

# Existing entry points delegate to the canonical account-data generator:
bin/rails generate provider:bank_data acme_bank api_key:text:secret
bin/rails generate provider:family acme_bank api_key:text:secret
bin/rails generate provider:global acme_bank client_id:string secret:text:secret
```

`provider:account_data`, `provider:bank_data` and `provider:family` default declared
fields to `connection` scope. `provider:global` defaults them to `application` scope.
Either can be set
explicitly using `--credential-scope=connection|application`. All provider connections
remain family-owned. Installation credentials and per-connection tokens can coexist;
the scope controls this declaration, not the ownership of a provider connection. Before
activating a mixed-auth provider, extend its definition with both credential sets
as part of the shared credential/authentication runtime.

These generators are for account ingestion. Use the existing
[securities provider guide](../llm-guides/adding-a-securities-provider.md) for market
data; do not create bank connections for exchange-rate, LLM or property providers.

`Provider::AccountData` is the canonical integration namespace for bank, brokerage
and crypto accounts. `Provider::BankData` remains an alias of the same module;
existing adapter definitions and exception handling keep working. Both provider
namespaces expose `Record` as a compatibility alias of the source-independent
`Ingestion::Record`, which can also carry normalized values from file imports.

## Output

For `acme_bank`, exactly four integration-owned files are generated:

| Path | Responsibility |
| --- | --- |
| `app/models/provider/account_data/acme_bank.rb` | Definition and adapter normalization |
| `app/models/provider/account_data/acme_bank/client.rb` | Injected upstream transport |
| `test/models/provider/account_data/acme_bank_test.rb` | Identity/privacy checks and deliberately failing implementation acceptance tests |
| `docs/providers/acme_bank.md` | Configuration and implementation checklist |

There are no per-provider migrations, models for persisted connections/accounts,
routes, UI fragments or edits to shared enums/controllers. The former family
default of investment has changed to **banking**; select investment explicitly.
Legacy `--skip-migration`, `--skip-models`, `--skip-routes`, `--skip-controller`,
`--skip-view` and `--skip-adapter` options are rejected: the generator no longer
owns those surfaces. `--pretend`, `--skip`, `--force`, destination roots and Rails
generator revocation use ordinary Thor file actions. Review `--force` output before
overwriting an implemented integration.

## Fields and defaults

Use a lowercase snake_case provider key without slashes, namespaces or punctuation.
Fields require `name:type[:secret][:default=value]`:

- Supported types: `string`, `text`, `integer`, `boolean`.
- Names must be snake_case and unique within the declaration.
- Provider keys cannot shadow contract classes, the registry or errors, including
  `record`, `registry`, `migration_cutover`, `invalid_response`, `stale_writer`
  and `incomplete_page`. This also applies to `--force` and generator revocation.
  The generator test inventories shared runtime files to catch newly added names
  that have not been reserved.
- `secret` describes encrypted runtime credential storage; it never masks an
  otherwise plaintext value or permits committing a real credential.
- Secret defaults are rejected. Supply secrets at runtime.
- Boolean defaults are exactly `true` or `false`; integer defaults are decimal
  integers. String defaults retain colons, quotes, newlines and URL punctuation
  through Ruby string escaping. No default is evaluated as Ruby.
- These are field declarations, not database columns. Configuration can use names
  such as `institution_id` without colliding with shared relational fields.

## Normalization contract

`Provider::AccountData::Definition` declares the stable key, existing ingestion
`source`, scope, fields and capabilities. Source is distinct from key so that
migrations preserve namespaces such as Plaid's `plaid` across region variants.
`Adapter` receives an injected client and performs no persistence or scheduling.

The [shared account setup command](../architecture/provider-native-account-setup.md)
owns discovery presentation, authorized account creation/linking and source policy
selection. An adapter opts in separately through `self.account_setup_types`; the
default is empty. `self.account_setup_resources` defaults to balances plus declared
capabilities; a provider requiring historical balances must declare that resource
too. Review retained unlinked history, account-type/balance semantics and the native
lifecycle before opting in. Generating a package never creates provider-specific
setup controllers or permits secondary sources to replace existing authority.

Optional `self.account_setup_defaults(account:, accountable_type:)` receives
frozen nonsecret source context. It may return a valid `subtype` and decimal-string
`cash_balance` for a new account; the shared command validates and signs those
values. It cannot override explicitly entered account values or mutate existing
accounts. Leave the inherited empty defaults unless the integration needs them.

Scope follows the upstream protocol, regardless of whether the source is a direct
institution or an aggregator. Ordinary transaction/activity methods are account
scoped. A connection-wide feed declares `transaction_scope` or `activity_scope`
as `:connection` and implements the corresponding group method. Activity groups
carry resource `activities`; their shared barrier is distinct from transaction
groups and holdings snapshots. Resuming a captured activity prefix requires an
explicit `resumable_activity_groups?` contract. See the [generation
protocol](../architecture/connection-change-sets.md) before enabling that behavior.

An integration with a different initial transaction-history boundary can override
the pure `initial_history_start(account:, observed_at:)` adapter method. Its
default is 90 days; `nil` means accessible history without an initial start date.
Declare any metadata inputs through `self.initial_history_metadata_keys` so the
runtime can pin them when selecting and admitting the request. Explicit dates and
completed checkpoint coverage take precedence. See the
[history-window contract](../architecture/provider-history-windows.md); test through
the shared syncer because a direct adapter call can hide an overridden default.

Account-scoped fetch methods return `Provider::AccountData::Page`:

```ruby
transaction = Ingestion::Record.transaction(
  external_id: "existing_provider_prefix_123",
  name: "Coffee",
  date: Date.new(2026, 9, 14),
  amount: BigDecimal("4.25"),
  currency: "USD",
  pending: false,
  metadata: { "provider_namespace" => { "pending" => false } }
)

Provider::AccountData::Page.new(
  records: [transaction],
  mode: "delta",
  complete: true,
  removed_ids: [],
  coverage: { "start" => "2026-09-01", "end" => "2026-09-14" }
)
```

Use `Ingestion::Record.account`, `.transaction`, `.holding` and `.activity` to construct
immutable typed values. Required fields are defined in
[`Ingestion::Record`](../../app/models/ingestion/record.rb). Monetary amounts,
quantities and prices require finite `BigDecimal`; record dates require `Date`.
Unknown balances/prices may be omitted, and must not be replaced with zero.
Metadata preserves namespaced pending/FX fields. The domain bridge must
map these values to the existing import adapter and extend investment contracts
where a provider needs additional semantics.

`Page` distinguishes snapshot from delta, explicit completeness, an opaque next
page cursor, a separate `checkpoint_cursor` for the next sync, removals, actual
coverage and recoverable warnings. A complete result may carry a checkpoint (for
example an account history checkpoint), but cannot also have a next page. The runtime
commits that checkpoint only after durable application. Fetch methods also accept
`window:` for the requested `start`/`end` dates; the runtime must validate this
request context and adapters report the actual coverage. Incomplete results may
have no continuation when the
upstream response is partial. Only the shared runtime can establish that
an entire snapshot chain is authoritative, apply removal policies, persist batches
or commit checkpoints. The presence of `complete: true` alone does not authorize
deleting financial records.

An incomplete page can also supply `progress_cursor` to retain partial fetch
progress without advancing completed coverage. By default that progress can resume
in a later sync. Override `progress_cursor_scope(stream:)` to return `:sync` for
offsets tied to one captured snapshot: retries of that logical Sync resume the
offset, while a new Sync starts from the last completed checkpoint. The runtime
retains the previous batches and verifies the actual checkpoint before replacing
progress. This scope does not change a completed `checkpoint_cursor`'s lifetime;
do not put a snapshot-specific offset in that field. On-chain inventory and
activities use this contract. Behavioral verification remains pending.

For a connection-wide transaction log, override `transaction_scope` to return
`:connection` and implement `fetch_transaction_group(start_cursor:, generation_id:,
cursor:)`. Return an immutable `Provider::AccountData::TransactionGroup` containing
the account pages and original/request/next cursors. Its individual pages are
provisional. The shared runner captures the complete generation, seals bounded
account batches and promotes the connection cursor only after all children commit.
An interrupted provisional fetch restarts at the committed cursor; a sealed
generation resumes publication from stored evidence. See the
[generation protocol and its remaining acceptance gates](../architecture/connection-change-sets.md).
Plaid's item-wide cursor uses this contract. Do not initialize account-scoped
cursors from it or wrap the same cursor in separate per-account checkpoints.

Unhandled methods raise `Provider::AccountData::NotImplementedError`, a regular
`StandardError`, so they cannot silently turn into empty successful imports.
Unsupported optional resources raise `UnsupportedCapability`. Transport failures
must raise sanitized errors; the runtime will capture support-relevant incidents
with `DebugLogEntry.capture` and family/connection context.

## Verification and activation

Replace each generated failing test with fixture/VCR assertions for real responses.
Cover identity replay, sign/currency/FX normalization, account discovery, pending
settlement, pagination, removals, complete empty versus partial results, rate limits
and authentication failures. Investment adapters also need holdings and activity
parity. Preserve existing provider SDKs where useful.

Run the focused generated tests and the repository's
[required checks](../llm-guides/development.md#before-opening-a-pull-request).
Activation additionally requires the architecture's persistence, authorization,
credential, registry, shared UI and sync gates; migration requires each provider's
copy verification and rollback gates. Existing account archives also require the
[retained ownership index](../architecture/provider-retained-account-index.md),
including older versions, before copy/preparation coverage can be accepted.
Generating four files is the beginning of an
integration, not evidence that a provider or its existing data has migrated.
