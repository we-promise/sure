# Architecture and development conventions

Read the relevant models and [schema](../../db/schema.rb) before changing domain
behavior. The application supports `managed` and `self_hosted` modes through
`Rails.application.config.app_mode`; see [application configuration](../../config/application.rb).
Provider availability can differ between installations.

## Design conventions

- Push built-in Rails functionality before adding dependencies. A new dependency
  needs a strong technical or business reason; favor established, reliable tools.
- Keep controllers thin and business logic in `app/models/`, organized with POROs
  and concerns rather than introducing service-object directories. A concern may
  serve one model, but organize it around a model trait rather than merely moving
  code elsewhere. Prefer `account.balance_series` to `AccountSeries.new(account).call`.
- Optimize for clear object design and readability. Focus performance work on
  critical paths and shared surfaces: avoid N+1 queries and loading large payloads
  in global layouts; use indexes, eager loading, background jobs and caching where
  they address a real cost.
- Put simple constraints such as null checks and uniqueness in the database.
  ActiveRecord may mirror them for form error handling; prefer client-side form
  validation where possible. Keep complex validation and business logic in Ruby.
- Use semantic HTML and Hotwire, server-side formatting and URL state. Detailed
  component, Turbo, Stimulus and design-system rules are in [UI guidance](ui.md).

## Families, users and currencies

[Family](../../app/models/family.rb) owns financial accounts, users, subscriptions
and many preferences. [User](../../app/models/user.rb) belongs to a family;
[Session](../../app/models/session.rb) belongs to a user. Roles include guest,
member, admin and super admin. Accounts also have an optional user owner and
sharing rules, so family membership alone does not describe every user's access.
Use [Current.user and Current.family](../../app/models/current.rb), and the existing
account-access scopes for the surface being changed.

An [Account](../../app/models/account.rb) has its own balance and currency.
[Entries](../../app/models/entry.rb), [balances](../../app/models/balance.rb) and
[holdings](../../app/models/holding.rb) also retain currencies. The family's
preferred currency is used to normalize reports; it does not mean every stored
amount is already in that currency. [Money](../../lib/money.rb) handles monetary
operations and formatting, with [ExchangeRate](../../app/models/exchange_rate.rb)
and its [Provided concern](../../app/models/exchange_rate/provided.rb) supplying
dated conversion rates.

## Accounts, balances and entries

Account uses a delegated `accountable` type. The supported types are defined in
[Accountable](../../app/models/concerns/accountable.rb): asset types `Depository`,
`Investment`, `Crypto`, `Property`, `Vehicle`, `OtherAsset`; liability types
`CreditCard`, `Loan`, `OtherLiability`.

A daily balance records what an asset is worth or what is owed on a liability.
For a depository account this is cash; for an investment account it includes cash
and holdings value. A holding records an account's quantity and price of a
[Security](../../app/models/security.rb) on a date. [Balance::Materializer](../../app/models/balance/materializer.rb)
materializes holdings through [Holding::Materializer](../../app/models/holding/materializer.rb)
before calculating balance history.

Entry delegates to one of the three [Entryable types](../../app/models/entryable.rb),
with a date, amount and currency:

- [Valuation](../../app/models/valuation.rb) is an absolute account value or debt
  at a date, not an income or expense.
- [Transaction](../../app/models/transaction.rb) changes the account balance and
  can have a category, merchant and tags; rules can enrich or classify it.
- [Trade](../../app/models/trade.rb) represents a security movement with quantity
  and price, including buys and sells.

For cash movements, **negative entry amounts are inflows; positive amounts are
outflows**. A negative checking transaction increases cash; a negative credit-card
transaction is a payment that reduces debt. A sale's negative entry amount
increases investment-account cash. Do not apply movement signs to an absolute
valuation or confuse cash direction with asset/liability balance direction.

## Transfers

[Transfer](../../app/models/transfer.rb) pairs an inflow and outflow transaction
between different accounts in the same family. Same-currency amounts must be equal
and opposite. [Family::AutoTransferMatchable](../../app/models/family/auto_transfer_matchable.rb)
normally searches a four-day window and also supports cross-currency candidates
using dated exchange rates and a tolerance. Confirmed transfers permit a
thirty-day date difference; do not assume every transfer is a same-currency,
four-day match.

The destination determines the outflow's kind: loan payment, credit-card payment,
investment contribution or ordinary funds movement. In [Transaction's budget
classification](../../app/models/transaction.rb), funds movement and credit-card
payments are excluded, while loan payments and investment contributions count as
expenses. Preserve these distinctions rather than treating every transfer as
excluded from income/expense reporting.

## Ingestion and background work

Provider connections such as [PlaidItem](../../app/models/plaid_item.rb) hold
connection metadata and provider account payloads; processors normalize them into
internal accounts and entries through [Account::ProviderImportAdapter](../../app/models/account/provider_import_adapter.rb).
[AccountProvider](../../app/models/account_provider.rb) connects accounts to
provider records. [Import](../../app/models/import.rb) supports manual import
sessions, including CSV mapping and transformations. Plaid is one of many supported
provider integrations.

[Syncable](../../app/models/concerns/syncable.rb) schedules background syncs and
[Sync](../../app/models/sync.rb) records their state, hierarchy and errors.
[Account::Syncer](../../app/models/account/syncer.rb) imports market data,
materializes history (reverse for linked accounts, forward for manual accounts),
applies provider balance overrides and matches transfers after sync.
[Family::Syncer](../../app/models/family/syncer.rb) schedules all eligible Syncable
`*_items` associations plus manual accounts, then matches transfers and applies
active rules. Entry-changing workflows call `Entry#sync_account_later`; inspect
the calling workflow rather than assuming every save schedules a full sync.

[AutoSync](../../app/controllers/concerns/auto_sync.rb) can request a family sync
on login once per date when the family enables it and has active accounts.
[AutoSyncScheduler](../../app/services/auto_sync_scheduler.rb) and the
[Sidekiq schedule](../../config/schedule.yml) handle scheduled work. Sidekiq also
runs [SyncJob](../../app/jobs/sync_job.rb), [ImportJob](../../app/jobs/import_job.rb)
and [AssistantResponseJob](../../app/jobs/assistant_response_job.rb).

## Provider interfaces and APIs

Interchangeable provider concepts are registered at runtime through
[Provider::Registry](../../app/models/provider/registry.rb) and
[Setting](../../app/models/setting.rb), with environment overrides where supported.
Interfaces live in `app/models/provider/*_concept.rb`, including
[SecurityConcept](../../app/models/provider/security_concept.rb) and
[ExchangeRateConcept](../../app/models/provider/exchange_rate_concept.rb).
One-off integrations can expose concrete methods without inventing a shared
concept. Domain models should normally select providers through their `Provided`
concerns rather than calling the registry throughout business logic.

Concept providers inherit from [Provider](../../app/models/provider.rb) and use
`with_provider_response` to return `Provider::Response` (`success?`, `data`,
`error`). Raise when valid data cannot be produced inside that wrapper; it
converts failures into the response contract. See [provider guidance](providers.md)
and [adding a securities provider](adding-a-securities-provider.md) for details.

Web interaction uses Turbo/Stimulus with server-rendered views. External
`/api/v1` endpoints support separate Doorkeeper OAuth and `X-Api-Key`
authentication; API keys are opaque keys, not JWTs. The [API base controller](../../app/controllers/api/v1/base_controller.rb)
sets current context, skips session CSRF checks and applies API-key rate limits.
Preserve the existing authentication, scope and strong-parameter behavior. Follow
the [API consistency guide](api-endpoint-consistency.md) for behavioral tests and
documentation-only rswag specs; its API-key convention does not remove runtime
OAuth support.
