# Provider integration guidance

Read [architecture](architecture.md) for provider concepts, runtime registry
selection and `Provided` concerns. For a new securities price provider, follow
[the complete workflow](adding-a-securities-provider.md), including response
types, MIC mapping, currency handling, settings encryption, UI, locales and tests.

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
[`Transaction#pending?` and pending scopes](../../app/models/transaction.rb) share
`PENDING_PROVIDERS`; that constant is the current list of supported namespaces,
including providers beyond the three described below. The UI shows a Pending
badge when `transaction.pending?` is true. A provider that supplies no pending
metadata produces no badge; manual/CSV imports have no pending concept.

| Provider | Detection and storage |
| --- | --- |
| SimpleFIN | [`SimplefinEntry::Processor.pending?`](../../app/models/simplefin_entry/processor.rb) accepts an explicitly truthy `pending` flag, or `posted` equal to numeric `0` or string `"0"` with a present, positive `transacted_at` timestamp. A blank/missing `posted` value does **not** imply pending. Writes `extra["simplefin"]["pending"]` as true or false so a posted update clears stale pending metadata. |
| Plaid | [`PlaidEntry::Processor`](../../app/models/plaid_entry/processor.rb) stores bank/credit transaction `pending` and `pending_transaction_id` under `extra["plaid"]`; the linking ID supports pending-to-posted reconciliation. The investment transaction processor does not store pending metadata. |
| Lunchflow | [`LunchflowEntry::Processor`](../../app/models/lunchflow_entry/processor.rb) stores the boolean-cast `isPending` value under `extra["lunchflow"]["pending"]` when the upstream key is present. |

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
