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

## Dividends and interest are trades

Investment income is a trade with no quantity: `qty: 0`, `price: 0`, the cash
value on the `Entry` (negative for an inflow), and an `investment_activity_label`
of `"Dividend"` or `"Interest"` (`Trade::INCOME_LABELS`). That is what
[`Trade::CreateForm#create_income_trade`](../../app/models/trade/create_form.rb)
builds for manual entry, and provider syncs must match it — otherwise the same
event has two shapes depending on how it arrived, and
[`InvestmentStatement`](../../app/models/investment_statement/totals.rb), which
aggregates over trades, cannot see the synced half.

So import them through `import_trade` like any other trade, never through
`import_transaction` with an income label. Two things to get right at the call
site:

- **Security.** `import_trade` requires one. Pass the paying instrument when the
  provider names it; it belongs in the association, not in an
  `extra["security_id"]` that a `Transaction` had to stash it in. Interest
  usually names nothing, so fall back to `Security.cash_for(account, currency:)`,
  which is what manual interest entry does.
- **Accounts that cannot hold trades.** A connection may be linked to a
  `Depository` account (Trade Republic allows both), and interest paid into an
  ordinary cash account is not a trade — there is no position for it to sit
  against. Check `Account#supports_trades?` and keep the cash-movement
  representation there. This matches the manual rule, which makes income a trade
  *in an investment account*.

`investment_activity_label` must be canonical English from
`Trade::ACTIVITY_LABELS`; `Trade` validates it, so a localized label ("Kauf",
"Dividende") fails validation and drops the entry. Localize the entry `name`
instead.

### Income imported before it was a trade

`import_trade` raises on an entryable-type mismatch, with one narrow exception:
an income trade landing on an `external_id` that already holds a `Transaction`.
Provider syncs used to import dividends and interest that way, and accounts
connected back then still hold those rows. That case leaves the existing row
untouched, records a skip and writes a rate-limited `DebugLogEntry`. Every other
mismatch still raises.

The old row is kept rather than converted because `Transaction` carries
`merchant`, `transfer`, `taggings` and `attachments`, none of which `Trade` has a
column for. The sync protection flags are not a sufficient guard either:
`determine_skip_reason` checks only `excluded`, `user_modified` and
`import_locked`, while rules and auto-categorization write through
`locked_attributes`, and attaching a file marks nothing at all. So the new
representation applies to new events only.

The log is rate-limited to one entry per account per source per day: a provider
that re-delivers its whole history on every sync (Trade Republic reprocesses up
to 5,000 stored timeline events) would otherwise write a row per skipped entry,
forever.

The entry is logged at `warn` with the remedy in the message — deleting the
Transaction lets the next sync import it as a Trade — because nothing else
surfaces the condition to an operator.

This is a workaround for a past mistake, not a permanent feature. Once those rows
have aged out of every provider's fetch window, `legacy_trade_income_transaction?`
and its logging can be deleted.

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
