# Domain Architecture and Data Flow

This is a navigation guide to the financial domain. Shared development rules live in
[AGENTS.md](../../AGENTS.md). Check the linked implementations and
[database schema](../../db/schema.rb) when changing behavior; provider details and
calculation boundaries vary by integration and account type.

## Ownership and Account Types

[Family](../../app/models/family.rb) groups users and financial accounts.
[Account](../../app/models/account.rb) belongs to a family, may have a user owner, and can be
shared through [AccountShare](../../app/models/account_share.rb). Family membership
alone does not establish permission to access or modify every account. Follow
[User#accessible_accounts](../../app/models/user.rb) and the account's permission
methods; web mutation permissions also use
[AccountAuthorizable](../../app/controllers/concerns/account_authorizable.rb).

An account delegates its type-specific behavior to an `accountable` record.
[Accountable::TYPES](../../app/models/concerns/accountable.rb) lists the supported
types. The account owns entries, balances, and holdings. Its classification is
`asset` or `liability`; its `balance_type` distinguishes cash, non-cash, and
investment calculations. Both Investment and Crypto use the investment balance type.

Accounts, entries, and holdings retain their own currencies. Use the existing
[Money](../../lib/money.rb) and
[ExchangeRate](../../app/models/exchange_rate.rb) paths for conversion; a family's
preferred reporting currency does not mean every stored amount uses that currency.

## Entries and Signs

[Entry](../../app/models/entry.rb) carries the account, date, amount, and currency,
and delegates to a type in [Entryable::TYPES](../../app/models/entryable.rb):

- [Transaction](../../app/models/transaction.rb) records a financial flow.
- [Trade](../../app/models/trade.rb) records security activity and its quantity/price.
- [Valuation](../../app/models/valuation.rb) supplies an absolute account value or
  debt at a date, including opening/current anchors and reconciliation values.

For transaction and trade flows, a negative `Entry.amount` is an inflow and a
positive amount is an outflow. Negative flows increase asset balances and reduce
liability balances; positive flows do the reverse. See
[Balance::ForwardCalculator](../../app/models/balance/forward_calculator.rb).
Valuations are absolute values, so do not interpret their amounts as flows.

Trade quantity has a separate sign convention: positive `qty` is a buy and negative
`qty` is a sell. Some imported trades represent cash income with zero quantity;
[Balance::BaseCalculator](../../app/models/balance/base_calculator.rb) handles those
separately from trades that move holdings. Do not infer a trade's activity solely
from the sign of its cash amount.

## Historical Balances and Holdings

[Account::Syncer](../../app/models/account/syncer.rb) imports needed market data and
uses [Balance::Materializer](../../app/models/balance/materializer.rb) to calculate
and persist historical balances. Linked accounts use reverse calculation; manual
accounts use forward calculation. Follow the calculators and
[account anchors](../../app/models/account/anchorable.rb) for the actual date
boundaries and reconciliation behavior.

Balance materialization first invokes
[Holding::Materializer](../../app/models/holding/materializer.rb).
[Holding](../../app/models/holding.rb) represents an account/security position at a
date, with quantity, price, amount, and currency. Holdings feed the investment
balance's non-cash component. Materialization respects provider snapshots and
locked cost basis; preserve those rules when changing derived history.

## Transfers and Budget Treatment

[Transfer](../../app/models/transfer.rb) pairs an inflow transaction with an outflow
transaction from another account in the same family.
[Family::AutoTransferMatchable](../../app/models/family/auto_transfer_matchable.rb)
finds same-currency, equal-and-opposite candidates and also supports cross-currency
candidates using historical exchange rates and tolerance. Follow that implementation
for matching windows, exclusions, and previously rejected pairs.

The destination account determines the outflow transaction's kind. Budget treatment
depends on [Transaction's kind definitions](../../app/models/transaction.rb): funds
movement and credit-card payments are excluded, while loan payments and investment
contributions remain included. Do not exclude every transfer indiscriminately.

## Provider Connections and Syncs

[AccountProvider](../../app/models/account_provider.rb) links an internal account to
a polymorphic provider account. [Account::Linkable](../../app/models/account/linkable.rb)
also handles legacy Plaid/SimpleFIN links. Follow each integration's importer and
processor to trace raw payloads into internal accounts, entries, and holdings;
[PlaidItem::Syncer](../../app/models/plaid_item/syncer.rb) is one example.

[Syncable#sync_later](../../app/models/concerns/syncable.rb) schedules
[SyncJob](../../app/jobs/sync_job.rb) with a [Sync](../../app/models/sync.rb) record
that tracks status, errors, parent/child work, and calculation windows. Execution
delegates to the model's `Syncer`. [Family::Syncer](../../app/models/family/syncer.rb)
discovers syncable provider items and manual accounts; account post-sync work
matches transfers. Entry mutation callers explicitly request account syncs through
`Entry#sync_account_later`; do not assume every model save enqueues one.

[AutoSync](../../app/controllers/concerns/auto_sync.rb) gates login-triggered syncs
on family settings and prior activity. Consult
[scheduled jobs](../../config/schedule.yml) for recurring work.

For interchangeable market-data or other concepts, model-local `Provided` concerns
select providers through [Provider::Registry](../../app/models/provider/registry.rb).
[ExchangeRate::Provided](../../app/models/exchange_rate/provided.rb) illustrates the
pattern. Configuration and environment precedence are provider-specific.
[Provider#with_provider_response](../../app/models/provider.rb) returns a
`Provider::Response` with `success?`, `data`, and `error` fields; callers must handle
unconfigured providers and unsuccessful responses.
