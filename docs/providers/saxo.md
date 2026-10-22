# Saxo Bank (Preview)

Saxo is a native Sure investment provider. Enable Preview in Preferences, then
configure the LIVE application key and secret in Settings → Hosting. Both values
are stored using the existing encrypted Setting mechanism. As with other provider
settings, `SAXO_APP_KEY` and `SAXO_APP_SECRET` can supply initial values; settings
saved in Sure take precedence. Register the exact callback URL shown in Hosting
with your Saxo application. Request Personal Read access.

Enable market data for OpenAPI in SaxoTraderGO under Account → Other → Open API
Data Access (some regions use Account → Other → OpenAPI Access first). Review
Saxo's terms and any applicable market data subscriptions. Without access,
Saxo can return zero prices even when positions exist; Sure stops the sync and
shows a message instead of importing zero valuations. Saxo documents the steps
in its [market data guide](https://www.developer.saxo/excel/user-guide/enabling-market-data).

Open Accounts → New account → Investment → Link with Saxo Bank, authorize access
on Saxo's website and return to Sure. Select a manual Investment account in the
same currency or create a new account. PEA and PEA-PME use the PEA subtype; other
securities accounts use Brokerage. The first discovery runs in the background;
refresh the setup page when it finishes. No bank password, application JSON or
bridge container is used.

## Data and accounting

The first synchronization reads history from 2010; later runs start 60 days before
the last successful synchronization, covering interruptions as well as recent corrections.
Manage accounts provides a complete-history reconciliation action. All pages and
calendar-year windows are read. Intraday entries are deferred until booked.

Stock, ETF and ETC positions are imported as holdings, with stable listing identities
based on Saxo UIC and asset type. These securities are initially offline: Sure
uses Saxo's supplied valuations rather than guessing exchange MICs or market-data
symbols. Users may remap securities with Sure's existing holding tools.

Buys and sells create Trade entries. Principal cash bookings already represented
by those trades are excluded from cash transactions. Commissions, dividends,
taxes and transfers retain individual BookingId identities. Amounts use the
account currency; foreign instrument prices are converted only with the explicit
Saxo rate, with original currency, quote price and conversion retained on the
trade. Total value and cash balance remain separate.

A complete holdings snapshot writes zero snapshots for sold positions and keeps
historical holdings. Manual entry changes and locked holding cost bases are
preserved. Unsupported instruments, non-cash corporate actions, missing trade
principal information and inconsistent currencies or cash totals fail the sync
with a diagnostic instead of fabricating records. All linked accounts are
validated before writing financial data.
Saxo valuations marked `OkWithConditions` are accepted when open positions have
positive prices and values; Saxo reports that their calculations have conditions.

## Session maintenance

Keep Sidekiq and its scheduled jobs running. `RefreshSaxoSessionsJob` checks
sessions every five minutes, renewing either token before expiry. Token rotation
is serialized with a database row lock and persisted before releasing that lock.
If authorization expires or Saxo rejects it, the connection requests reconnection
from Sure. Refresh maintenance does not reimport financial history.

Disconnecting removes local credentials and provider links, while keeping Sure
accounts and their financial history. It stops scheduled requests. Revoke the
application's consent in Saxo as well when you want provider-side revocation.

## Deployment

Apply `20261022120000_create_saxo_connections` with the normal deployment process
before enabling Saxo. The implementation does not apply migrations automatically.
There is no automatic migration of records from the experimental external bridge.
If that bridge was activated elsewhere, stop it and reconcile its imported data
before attaching the native provider; do not run both writers on one account.

Reference: [OAuth](https://www.developer.saxo/openapi/learn/oauth-authorization-code-grant),
[transactions](https://www.developer.saxo/openapi/learn/transactions),
[balances](https://www.developer.saxo/openapi/referencedocs/port/v1/balances/get__port).
