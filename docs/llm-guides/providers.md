# Provider integration guidance

Read [architecture](architecture.md) for provider concepts, runtime registry
selection and `Provided` concerns. For a new securities price provider, follow
[the complete workflow](adding-a-securities-provider.md), including response
types, MIC mapping, currency handling, settings encryption, UI, locales and tests.

## Provider logos

A provider's logo comes from [`ProviderLogo`](../../app/components/provider_logo.rb): the
Brandfetch icon for the `domain` in its
[`Provider::Metadata::REGISTRY`](../../app/models/provider/metadata.rb) entry, falling back
to `logo_icon`, then `logo_text` initials on `logo_color`. Anything identifying a provider
renders `render ProviderLogo.new(provider_key: :<x>)` — the `_<x>_item` card on Accounts,
the Bank Sync cards and connection rows, and the connection rows in
`settings/providers/_<x>_panel` — rather than a hand-built badge or the first letter of a
connection name. A panel's setup form and instructions carry no logo.

Give each new provider a registry entry with a brand domain. Only a provider with no single
brand behind it (on-chain wallets) omits the domain and sets `logo_icon` instead.
Institution logos are a separate concept and belong on accounts through
`Account#logo_url`, never on a provider.

## Support diagnostics

When a provider sync/import path encounters a recoverable error, suspicious partial
response or other support-relevant incident, prefer
[`DebugLogEntry.capture`](../../app/models/debug_log_entry.rb) over `Rails.logger.*`
so operators can inspect it in the super-admin `/settings/debug` UI.

- Include `category`, `level`, `message`, `source`, `provider_key` and useful
  structured `metadata`.
- Attach `family` and `account_provider` whenever available so support can filter
  and trace the affected connection. Account/user associations can add context.
- Reserve raw Rails logging for low-value local noise; incidents operators need
  to investigate belong in the debug log.

## Pending transactions and FX metadata

Store provider metadata on `Transaction#extra` under the provider namespace.
[`import_transaction`](../../app/models/account/provider_import_adapter.rb) deep-merges
that hash, so a key the provider stops sending keeps its previous value. A provider
that owns its namespace outright passes `replace_extra_namespaces: ["<key>"]`. When the
incoming payload includes that namespace, the existing namespace is replaced, so omitted
nested fields are removed. Send the provider's current namespace snapshot on every sync.
[`Transaction#pending?` and pending scopes](../../app/models/transaction.rb) share
`PENDING_PROVIDERS`; that constant is the current list of supported namespaces,
including providers beyond the three described below. The UI shows a Pending
badge when `transaction.pending?` is true. A provider that supplies no pending
metadata produces no badge; manual/CSV imports have no pending concept.

| Provider | Detection and storage |
| --- | --- |
| SimpleFIN | [`SimplefinEntry::Processor.pending?`](../../app/models/simplefin_entry/processor.rb) accepts an explicitly truthy `pending` flag, or `posted` equal to numeric `0` or string `"0"` with a present, positive `transacted_at` timestamp. A blank/missing `posted` value does **not** imply pending. Writes `extra["simplefin"]["pending"]` as true or false so a posted update clears stale pending metadata. |
| Plaid | [`PlaidEntry::Processor`](../../app/models/plaid_entry/processor.rb) stores bank/credit transaction `pending` and `pending_transaction_id` under `extra["plaid"]`; the linking ID supports pending-to-posted reconciliation. It also stores `original_description`, `payment_channel`, `transaction_code`, `payment_meta` and `counterparties`, and passes `replace_extra_namespaces: ["plaid"]` so the namespace is a snapshot of what Plaid currently reports. The investment transaction processor does not store pending metadata. |
| Lunchflow | [`LunchflowEntry::Processor`](../../app/models/lunchflow_entry/processor.rb) stores the boolean-cast `isPending` value under `extra["lunchflow"]["pending"]` when the upstream key is present. |
| Monobank | [`MonobankEntry::Processor`](../../app/models/monobank_entry/processor.rb) treats a `hold: true` statement item as pending and writes `extra["monobank"]["pending"]`. Monobank may settle a hold under a *different* id, so the settled record reconciles onto the pending entry through [`Account::ProviderImportAdapter`](../../app/models/account/provider_import_adapter.rb)'s amount/date lookup. A hold that simply disappears is pruned, but only when the statement request actually covered its date range, and never when the entry is `protected_from_sync?` — those only lose the pending flag. `currencyCode` on a statement item is the **operation** currency, not the account's — it varies between items on one account — so entries take their currency from `MonobankAccount#currency` and `currencyCode`/`operationAmount` populate `fx_from`/`fx_amount`. Those two are emitted only for a recognized foreign operation — a known `currencyCode` differing from the account currency, and for `fx_amount` a parseable `operationAmount`, whose failure is captured as a `provider_sync_error`. Independently of that, `operation_amount` keeps the raw minor-unit figure whenever it differs from `amount`. |

SimpleFIN additionally stores `extra["simplefin"]["fx_from"]` when transaction and
account currencies differ, and `fx_date` from the transacted date with posted-date
fallback. Preserve these namespaced fields and the existing conversion behavior.

Pending inclusion is provider- and layer-specific:

- **SimpleFIN:** the [initializer](../../config/initializers/simplefin.rb) defaults
  `config.x.simplefin.include_pending` to true. The
  [importer](../../app/models/simplefin_item/importer.rb) resolves an explicit
  `pending:` argument first, then a present `SIMPLEFIN_INCLUDE_PENDING` environment
  value, then `Setting.syncs_include_pending`. The entry processor also checks the
  environment/Setting choice before importing cached pending payloads.
  `SIMPLEFIN_INCLUDE_PENDING=0` disables the environment-controlled path.
  The [low-level provider](../../app/models/provider/simplefin.rb) does not resolve
  these settings: it adds `pending=1` only for a truthy argument, and otherwise
  omits the parameter. Do not send `pending=0`; bridges can interpret its presence
  as inclusion.
- **Plaid:** the [initializer](../../config/initializers/plaid_config.rb) defaults
  `config.x.plaid.include_pending` to true. The [transaction processor](../../app/models/plaid_account/transactions/processor.rb)
  uses a present `PLAID_INCLUDE_PENDING` environment value before
  `Setting.syncs_include_pending`; `PLAID_INCLUDE_PENDING=0` filters pending
  records out. This is processing-time filtering, not a pending query flag on the
  [Plaid sync request](../../app/models/provider/plaid.rb).
- **Shared SimpleFIN/Plaid setting:** [`Setting.syncs_include_pending`](../../app/models/setting.rb)
  defaults true with both environment variables absent. Its initial default is
  computed from both provider environment values; a persisted runtime setting can
  differ. Do not infer effective importer behavior from an initializer alone.
- **Lunchflow:** the [initializer](../../config/initializers/lunchflow.rb) defaults
  `config.x.lunchflow.include_pending` to false. Set `LUNCHFLOW_INCLUDE_PENDING=1`
  to enable it. The [importer](../../app/models/lunchflow_item/importer.rb) passes
  that configuration as `include_pending:`. A direct [provider call](../../app/models/provider/lunchflow.rb)
  defaults the argument to false and adds `include_pending=true` only when enabled;
  it does not consult the shared SimpleFIN/Plaid setting.
- **Monobank:** the [initializer](../../config/initializers/monobank.rb) defaults
  `config.x.monobank.include_pending` to true; `MONOBANK_INCLUDE_PENDING=0` imports
  only settled transactions. The same initializer bounds a sync against Monobank's
  one-request-per-minute limit and 31-day statement window
  (`max_statement_requests_per_sync`, `pending_lookback_days`,
  `initial_history_days`); read [the hosting guide](../hosting/monobank.md) before
  changing the [importer](../../app/models/monobank_item/importer.rb)'s request
  budgeting, and keep the pending lookback wide enough that live holds stay in the
  payload instead of being pruned as stale.

## Transaction naming

Where a provider supplies both a cleaned merchant name and the bank's own
description, combine them rather than choosing one:
[`SimplefinEntry::Processor`](../../app/models/simplefin_entry/processor.rb) emits
`"#{payee} - #{description}"` when both are present and differ, and
[`PlaidEntry::Processor`](../../app/models/plaid_entry/processor.rb) does the same
with `merchant_name` and `original_description`.

The merchant name alone collapses distinct transactions into one name, and
[rules](../../app/models/rule/condition.rb) match on `transaction_name`, so the
collapse removes the only signal that could separate them. Merchant records are
built from the cleaned name on a separate path, so grouping is unaffected.

Changing a name that rules already target is the cost of this, and it falls
entirely on the two operators with no substring tolerance. `transaction_name` is a
text filter, so it offers `=` and `!=` alongside `like`/`not_like`
([`condition_filter.rb`](../../app/models/rule/condition_filter.rb)); a `like` rule
written against the merchant name still matches the combined form, but an `=` rule
would stop matching and a `!=` rule would start matching what it was written to
exclude — silently, in both directions.

[`Rule::ConditionFilter::TransactionName`](../../app/models/rule/condition_filter/transaction_name.rb)
absorbs that: for `=` and `!=` only, a Plaid row also matches when its name is
exactly the rule's value joined to the stored `original_description` by
`PlaidEntry::Processor::NAME_SEPARATOR`. The comparison rebuilds the name; it does
not pattern match it. These properties make it safe, and a change here must
preserve all of them:

- **Exact, not a prefix match.** When Plaid resolves no merchant, the name is the
  bank's description alone, and banks write dashes of their own, so an ACH row
  reading "ACH - PAYROLL DEPOSIT" would satisfy `= "ACH"` under any
  `LIKE value || ' - %'`. That row's name was never changed by the combining, so
  matching it would break a rule on a row this feature does not touch. Rebuilding
  from the stored description means only a genuinely combined name can match.
- **Provenance-gated.** Rules run against every transaction in the family
  ([`resource_scope`](../../app/models/rule/registry/transaction_resource.rb)), not
  just provider rows. Without the `source` gate, `= "Rent"` would start matching a
  manually entered "Rent insurance".
- **Case-preserving.** `=` compiles to a plain `=` and stays case-sensitive.
- **NULL-safe.** `entries.source` is nullable, so the added arm is `NULL` for manual
  rows and a bare `NOT (...)` would drop them out of every `!=` rule. The predicate
  is wrapped in `COALESCE(..., FALSE)` before negation.
- **Kept in step with the name.** The comparison trusts that the stored
  `original_description` is the one the name was built from. A protected
  (user-modified) entry keeps its name when Plaid resends it, so the processor
  passes `name_extra_keys: { "plaid" => ["original_description"] }` and
  [`Account::ProviderImportAdapter`](../../app/models/account/provider_import_adapter.rb)
  keeps that value alongside the name rather than refreshing it. Without that, a
  bank rewriting a pending transaction's description as it settles would flip
  `=` and `!=` on an entry the user had already categorized.

`like` and `not_like` rules are deliberately left alone, and they do see the
change: the combined name contains the merchant as well as the description, so a
`like "Amazon"` rule now reaches `Amazon - AMZN Mktp US*...` rows it could not
before. That wider reach is the purpose of combining.

One known gap: `Entry#split!` gives each child no `source` and no `extra`, while the
split form prefills each child's name from the parent. A child of a combined Plaid
transaction therefore keeps the combined name but not the provenance, so `=` and
`!=` rules on the merchant do not reach it. Renaming the child, or using `like`,
does.

This is deliberately runtime behavior rather than a migration over saved rules:
rewriting operators in place is irreversible, changes rules the user chose, and
misses families who connect a provider later.

If another provider starts combining names, gate it the same way — do not widen the
rule engine generally. SimpleFIN is excluded on purpose: it has always emitted the
combined form, so its rules were written against it.

## Raw payload debugging

Raw debugging is default-off. `SIMPLEFIN_DEBUG_RAW=1` and
`LUNCHFLOW_DEBUG_RAW=1` enable their importers' raw response logging through
`Rails.configuration.x.simplefin.debug_raw` and
`Rails.configuration.x.lunchflow.debug_raw` respectively.

`UP_DEBUG_RAW=1` enables [Up's debug configuration](../../config/initializers/up.rb),
but its [importer](../../app/models/up_item/importer.rb) logs raw transactions only
when `Rails.env.local?` is also true. The dump contains PII: preserve this local-only
guard and do not enable raw Up dumps in managed/production. This guard is specific
to Up; the SimpleFIN and Lunchflow flags do not provide the same environment gate.

`MONOBANK_DEBUG_RAW=1` behaves like the Up flag: its
[importer](../../app/models/monobank_item/importer.rb) dumps raw payloads only when
`Rails.env.local?` is also true, because the dump contains PII (merchant and
counterparty names, IBANs, amounts, account ids). Preserve that local-only guard.

`FIO_DEBUG_RAW=1` has the same local-only guard in the
[importer](../../app/models/fio_item/importer.rb). Fio additionally authenticates by
putting the token in the **URL path**, so neither [the client](../../app/models/provider/fio.rb)
nor the importer may put a resolved URL into an exception message, a log line or debug
metadata; requests are labelled with a static operation name instead. Fio reports no
pending state, so it is deliberately absent from `Transaction::PENDING_PROVIDERS`.
