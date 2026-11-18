# Setting Up moomoo

[moomoo](https://www.moomoo.com) is a brokerage run by Futu, with entities in Singapore,
the US, Hong Kong, Malaysia, Australia, Japan and Canada. Sure reads moomoo accounts
through [moomoo OpenAPI](https://open.moomoo.com/api/overview/getting-started), with
read-only OAuth access that you grant on moomoo's own consent page. Sure never stores
your moomoo password and has no code that places or cancels orders.

This provider is in **alpha**. It has been run against a live moomoo Singapore universal
account, which confirmed part of what it relies on; the rest, for moomoo Singapore as for
the other moomoo entities, still rests on moomoo's documentation. See
[What a live account has confirmed](#what-a-live-account-has-confirmed) and
[Unverified assumptions](#unverified-assumptions).

## Before you start

- You need a moomoo account that is fully opened. You don't need a developer account or
  an API key.
- Sure registers an OAuth client with moomoo for its own address, so the address you use
  to open Sure is the one moomoo sends you back to. The moomoo panel in
  **Settings > Bank sync** shows it, for example
  `https://sure.example.com/moomoo_items/callback`.
- Behind a reverse proxy that doesn't pass the public host and scheme on to Sure, set
  `MOOMOO_REDIRECT_URI` to the public callback address.

## 1. Connect

1. In Sure, go to **Settings > Bank sync** and open **moomoo**.
2. Click **Connect moomoo**. Sure registers itself with moomoo and opens moomoo's
   consent page.
3. Sign in to moomoo. Tick only **trade:read** and the trading accounts you want in Sure,
   then confirm. Sure needs `trade:read` and at least one account; it doesn't need
   `quote:read`. Leave **trade:write** unticked. A consent that lets Sure place orders,
   or lacks `trade:read` or an account, is refused: Sure keeps nothing from it, and a
   connection you already had stays as it was. moomoo lists what you granted with the
   token; a token that lists nothing can't be checked, so Sure accepts it and the first
   sync shows whether it can read your accounts.
4. You come back to Sure's **Set Up moomoo Accounts** dialog while the first sync
   discovers your accounts. The dialog updates itself until the sync finishes. Then
   create a Sure account for each, or link one to an existing manual account of the same
   type and currency: a cash account for a moomoo cash account (see below), an investment
   account for the others. While a sync runs, the dialog lists what it has found so far
   and waits for it to finish before it lets you set accounts up.

To share more trading accounts, or fewer, with a connection you already have, click
**Change accounts** on its row in the moomoo panel (or in its menu on the Accounts page).
It runs moomoo's consent again for the same connection, and your linked accounts keep
their history.

Clicking **Connect moomoo** again connects another moomoo login. A consent you abandon
leaves a connection marked **Waiting for authorization**, which the next **Connect
moomoo** reuses. If two **Connect moomoo** consents run at once from the same address, the
first to finish is kept and the other asks you to connect again. From two addresses, only
the later one can finish, and the earlier one asks you to connect again.

## 2. What is imported

**Accounts.** Each trading account you shared becomes a moomoo account in Sure. A
securities account, including a universal account that can also trade futures or
crypto, can be linked as an Investment (brokerage) account, or, once split by currency,
as cash and stocks accounts (see below). Accounts with no securities market, such as
futures-only and crypto accounts, and moomoo Japan margin and derivative accounts, are
discovered and listed as not supported yet.

**Account currency.** moomoo converts an account's totals into the currency Sure asks
for. Sure asks for the home currency of the moomoo entity that holds the account:

| moomoo entity (`security_firm`) | Account currency |
| --- | --- |
| moomoo Singapore (`FUTUSG`) | SGD |
| Futu Securities Hong Kong (`FUTUSECURITIES`) | HKD |
| moomoo US (`FUTUINC`) | USD |
| moomoo Malaysia (`FUTUMY`) | MYR |
| moomoo Australia (`FUTUAU`) | AUD |
| moomoo Japan (`FUTUJP`) | JPY |
| moomoo Canada (`FUTUCA`) | USD (moomoo has no CAD) |

If moomoo answers in a different currency before you link the account, and before it is
split by currency, the account takes that currency. Once linked or split, an account keeps
its currency: a balance reported in another currency is not applied, and the sync logs an
error instead.

**Balance.** The account balance is moomoo's total net assets. Cash is the total minus
the holdings Sure imports, valued with Sure's exchange rates, so anything Sure doesn't
model (short positions, options, futures, forex) is counted as cash and the total stays
equal to moomoo's. Without an exchange rate, Sure uses moomoo's own cash figure.

**Accounts in more than one currency.** Sure keeps one cash balance per account, in the
account's currency. A moomoo account that holds more than one currency, for example a
moomoo Singapore account with Singapore dollars and US dollars, is split by currency into
a cash account for each currency and a stocks account for each currency with positions or
trades, each in its own currency: for example `moomoo SG ••3456 (SGD cash)`,
`moomoo SG ••3456 (USD cash)` and `moomoo SG ••3456 (USD stocks)`. An account counts as
holding a currency when it has cash or positions in it, or trades or cash movements in it
that Sure has stored.

An account that only ever holds one currency, its home currency or another, stays one
Investment account with its cash and its stocks, and pays for its trades from its own
cash, as most brokerage accounts in Sure do. It is split only once a second currency
appears.

- **Cash accounts** get their currency's cash log: deposits, withdrawals, dividends
  (including those of money market funds such as moomoo Cash Plus), coupons, interest,
  taxes, fees and currency exchanges. Their balance is the currency's cash, which counts
  the money market funds moomoo sweeps idle cash into.
- **Stocks accounts** get their currency's positions and trades. Each trade is paid from
  the cash account of its currency: Sure books the fill's value out of the cash account
  for a buy, or into it for a sell, and the opposite amount in the stocks account, and
  links the two as a transfer. The stocks account's cash stays at zero, and the cash
  account's history shows the buys and sells. The cash side is dated in the broker's
  timezone, like the cash log, and the stocks side on the trade's date, so a US trade
  made after midnight Singapore time is paid on the Singapore day after it. moomoo
  reports fees per order only, so the transfers carry none; the cash log's fee rows reach
  the cash account on their own. A transfer you remove with **Remove transfer** is linked
  again by the next sync. Positions Sure doesn't import, such as options, count as the
  stocks account's cash, so its total stays equal to moomoo's value of that currency's
  positions, except on the days before the split that are restated (see below).
- Cash accounts are cash (Depository, checking) accounts, so their money shows under
  Cash in net worth and on the Accounts page, like the cash a bank holds for you. Stocks
  accounts are Investment (brokerage) accounts. An existing manual cash account can be
  linked as a cash account, and a manual investment account as a stocks account.
- The transfers that pay for trades are plain funds movements on both sides, not
  investment contributions, so they stay out of budgets: the money only moves inside
  your moomoo account. Sure marks the buys' payments the way you would by turning off
  **Investment contribution** on a transfer, so later syncs and Sure's own repairs keep
  them so; you can turn it on for any of them, and that choice is kept too.
- A deposit from your bank account, or a withdrawal to it, moves money between two cash
  accounts. Sure imports it as a funds movement without an activity label; once it is
  matched with the bank's side as a transfer, both sides are funds movements, as for any
  transfer between your own cash accounts. A currency exchange between two moomoo cash
  accounts is a funds movement too, even when one of them is a manual investment account
  you linked, since it only converts cash inside your moomoo account.
- A cash account that Sure set up as an Investment account before cash accounts were cash
  accounts becomes a cash account on the next sync. It keeps its name, its page, its link
  to moomoo, and every transaction, transfer and balance; it moves from Investments to
  Cash on the Accounts page and in net worth, and shows categories instead of activity
  labels. Its deposits and withdrawals lose the Contribution and Withdrawal labels, and
  deposits the investment contribution kind and the Investment Contributions category
  those labels gave them. Whatever you changed yourself stays: a kind or category you
  chose, a category a rule set, or a label you picked. A deposit whose notes or name you
  edited keeps that edit, but still loses the label, kind and category. Unless you chose
  its kind, a transfer to or from it, other than a trade's payment or a currency
  exchange, takes the kinds Sure gives any transfer to or from a cash account, so one
  from it into an investment account becomes an investment contribution. An Investment
  account you created yourself and linked to a moomoo cash account stays as it is. A cash
  account that still holds another currency's trades, as the account you already linked
  can at the split, becomes a cash account in the sync that moves them. A trade you
  edited moves only once you set up that currency's stocks account; until then the cash
  account stays an Investment account, and each sync notes in the debug log that it is
  waiting on trades or holdings.
- The account you already linked keeps its link and its history. If its currency has
  positions or trades it becomes that currency's stocks account, and the currency's cash
  shows up in **Set Up moomoo Accounts** as a new cash account; otherwise it becomes the
  currency's cash account. Each other account shows up there to create or link.
- Until a currency's cash account is set up, its cash and cash log aren't imported
  anywhere, as for any account not set up: the stocks account doesn't take that cash,
  and still books its side of each trade. Once the cash account is set up, the cash log comes
  in there and the trades are paid from it. Until a stocks account is set up, its
  positions and trades aren't imported anywhere, though the cash account still books
  what each trade paid or received. The sync summary lists each account still to set
  up; until then, your accounts in Sure come to less than moomoo's total.
- Each sync keeps the day before's balance as a reconciliation that earlier days are
  worked back from. When the account you already linked becomes a stocks account, the
  ones it recorded before the split, which still counted its cash and any other
  currency, are restated as the value of the holdings imported that day, so the cash
  isn't counted again on every earlier day once the cash account has it; positions Sure
  doesn't import, such as options, are left out of those days. One for a day with no
  holdings imported is removed, as are those of an account that becomes a cash account.
  A balance you entered by hand, or changed by hand in any way after a sync recorded it,
  even only its notes, is left as it is, so it may still count the cash; edit its amount
  if it does.
- Trades and cash movements that a linked account was given in another currency before
  the split are removed from it, and are imported into that currency's account once you
  set it up. Its holdings are removed too; as moomoo only reports today's positions, the
  new account gets today's, and its earlier days' holdings are worked back from its
  trades.
- A trade or cash movement you edited stays where it is until the account it belongs in
  is set up, and then moves there.
- A currency exchange is a transfer between the two currencies' cash accounts, once both
  are set up.
- Today's balance of a cash account is its currency's cash; a stocks account's is the
  market value of its positions. moomoo reports cash per currency as buying power, which
  includes moomoo Cash Plus. Its total comes to about 99% of the account's cash and fund
  assets, so Sure scales each currency's figure to make them add up exactly. When the
  figures are more than 5% apart, or Sure has no exchange rate to compare them, Sure
  doesn't divide them: an account not split yet stays whole, and a split one keeps its
  last balances, with an error in the sync summary. Together, the accounts come to
  moomoo's cash, fund assets and positions, with the positions valued in their own
  currencies. That is moomoo's total, unless moomoo counts in it an asset it lists
  neither as cash, fund assets nor a position; a split account leaves such an asset out.
- Earlier balances are worked back from each account's own trades, transfers and cash
  movements. The growth of a money market fund such as moomoo Cash Plus isn't in the cash
  log, so the further back a day is, the more a cash account's balance can be off by that
  growth.

**Holdings.** Long stock and fund positions, each in the currency it trades in, so a US
share in a Singapore account is a USD holding. moomoo Cash Plus isn't among them: moomoo
reports its money market funds with the account's cash, and Sure counts them as cash. A
position moomoo stops listing, or lists with nothing left, is closed on the day of that
sync. The cost basis is the average cost per share, worked out from moomoo's market value
and unrealized P&L; moomoo's own "diluted" cost, which falls as you sell at a gain, is
not used. When moomoo marks its cost invalid or leaves out the unrealized P&L, Sure
averages the imported buys instead. A position listed without a market value is valued
at its price. One with neither isn't imported that day. Its value then counts as cash,
except in an account split by currency: there a stocks account's balance is only the value
of its positions, so the position counts as nothing that day and the accounts come to
less than moomoo's total. Sure looks each code up by ticker and exchange:

| moomoo code | Ticker | Exchange (MIC) | Trade date timezone |
| --- | --- | --- | --- |
| `SG.D05` | `D05` | SGX (`XSES`) | Asia/Singapore |
| `US.AAPL`, `US.PQR.B` | `AAPL`, `PQR.B` | any US exchange | America/New_York |
| `HK.00700` | `0700` | HKEX (`XHKG`) | Asia/Hong_Kong |
| `SH.600519`, `SZ.000001` | `600519`, `000001` | Shanghai (`XSHG`), Shenzhen (`XSHE`) | Asia/Shanghai |
| `JP.7203` | `7203` | Japan Exchange (`XJPX`) | Asia/Tokyo |
| `AU.BHP` | `BHP` | ASX (`XASX`) | Australia/Sydney |
| `BMS.1155` | `1155` | Bursa Malaysia (`XKLS`) | Asia/Kuala_Lumpur |
| `KR.005930` | `005930` | Korea Exchange (`XKRX`) | Asia/Seoul |
| `CA.SHOP` | `SHOP` | any Canadian exchange | America/Toronto |

A code Sure can't look up is kept as an offline security, named as moomoo names it. Once
a code has a security in an account, later syncs keep it there rather than looking it up
again, so a search that fails one day can't move its holdings and trades.

**Trades.** Every buy and sell fill in each securities market of the account (Singapore,
US, Hong Kong, China A-shares, Japan, Australia, Malaysia, Canada and Korea), going back
up to two years. Each fill is a trade in its order's currency, dated in its market's
timezone. Each sync rewrites every trade from its fill, so a fill moomoo later changes is
updated, and a change you make to a trade's date, quantity, price, amount or name is
undone by the next sync; its notes are kept. A fill moomoo cancels removes its trade,
unless you edited that trade in Sure.

### Cash movements

moomoo's cash log becomes transactions: bank deposits and withdrawals, dividends,
coupons, interest, taxes withheld, fees, and currency exchanges, each in the currency of
the balance moomoo shows beside it and dated in the broker's timezone (Singapore time for
moomoo SG). In an account split by currency, each row goes to its currency's cash
account, and the two rows of a currency exchange are linked as a transfer. Trade rows are
skipped, as the trades come from the fills, and so are subscriptions to and redemptions
from money market funds such as moomoo Cash Plus, which count as cash.

## 3. Not imported yet

- **Fees on trades.** Trades carry no fees; the cash log's fee rows come in as separate
  transactions instead (see Cash movements).
- **Short sales and buy-backs, options, futures, forex and crypto**, accounts with no
  securities market, such as those that only trade futures or crypto, and moomoo Japan
  margin and derivative accounts, whose balances moomoo reports one asset category at a
  time. The cash such a trade costs or brings is left out with it, as the cash log's trade
  rows are skipped, so on the days before it a cash account's balance differs from
  moomoo's by that amount.
- **Daily balances from moomoo.** moomoo has no balance history, so earlier balances are
  worked back only from the imported trades, transfers and cash movements, at most two
  years back.

## 4. Syncing

moomoo allows 100 requests a minute from one IP address. Sure spaces each sync's requests
at least 0.7 seconds apart, sends at most 90 a minute across all the moomoo syncs it runs
at once (`MOOMOO_MAX_REQUESTS_PER_MINUTE` changes it), waits for moomoo's `Retry-After`
when it is rate limited, and spends at most 250 requests per sync. The syncs keep their
count of requests in Sure's cache, which is Redis in a standard setup; while the cache
can't be reached, each sync keeps only its own spacing, so syncs running at once can go
over 90 a minute between them and be rate limited. The most important data comes first:
accounts, balances and positions, then recent trades and cash log entries, then older
history. When the budget runs out, Sure keeps what it fetched and the next sync carries
on; the connection shows **Older history still importing** until the two years of trades
are in. Older cash log entries, read after the trades, can still be coming in once it
has gone.

A first sync of a Singapore universal account trading in four markets takes about 90
requests, roughly two minutes. After that, each sync re-reads the last week of trades,
to pick up fills moomoo amended, and the last three days of cash log entries, which
takes about 16 requests. After a longer pause, a sync reads the newest 89 days first. The
rest of the time since the last sync is read with the older history, ahead of it, and
each sync picks up where the previous one stopped.

Fills and orders are fetched in windows of 89 days, inside moomoo's 90-day limit per
query. A window with more than 2,000 fills in one market is read on from its oldest fill
with further requests. If moomoo cuts a window of fills or cash log entries short with
no row to read on from, the rest of that window is skipped, and the sync summary lists
it. A market whose trade history fails on five syncs in a row stops
showing as importing, but every sync still retries it.

If moomoo won't answer for one shared account, the others still sync; that account keeps
its last balance and holdings, and the error shows in the connection's sync summary. The
sync fails when no shared account can be read, and also when, while it reads any
account's balances and positions, Sure can't renew its access token or moomoo still rate
limits Sure after its retries. Your accounts in Sure then stay as they were until a later
sync, since Sure only updates them once every account has been read. The balances and
positions already fetched for the accounts read before the failure are stored, but the
next sync reads every account again before using them. Once moomoo has failed to answer
for an account on five syncs in a row, that account no longer counts as importing older
history; a sync cut short by a rate limit or the access token doesn't count towards the
five. An account you stopped sharing keeps the balance and holdings of the day it was
last fetched, as does one whose balance moomoo reports in another currency or without a
total. That one's new trades, even if you link the account meanwhile, are imported with
its next usable balance, so the holdings history before them isn't counted twice.

## 5. Reconnecting

Access tokens last two hours and are renewed automatically; if moomoo's token endpoint
is briefly unavailable, Sure keeps using the current token until it expires. moomoo ends a
connection that hasn't been used for 14 days, so keep automatic syncing on; the moomoo
panel warns after 10 days without a sync. When moomoo no longer accepts the connection,
or the permissions you granted aren't enough, the connection shows **Reconnect required**
and a **Reconnect** button, which runs moomoo's consent again for the same connection.
Your linked accounts are matched up again by moomoo's account id, so they keep their
history.

If you open Sure at a new address, the next **Connect moomoo**, **Reconnect** or
**Change accounts** there registers Sure again for that address. An existing connection
keeps its registration, and keeps syncing, until that consent completes; a consent then
still open at the old address has to be started again. A **Connect moomoo** consent still
open at the old address stops working as soon as you click **Connect moomoo** at the new
one.

## 6. Removing a connection

**Remove** in the moomoo panel unlinks the accounts and deletes the connection; the
accounts in Sure keep their data. moomoo has no API to revoke access, so also remove
Sure in the moomoo OpenAPI dashboard
([open.moomoo.com/dashboard](https://open.moomoo.com/dashboard)).

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `MOOMOO_REDIRECT_URI` | derived from the request | Callback URL Sure registers with moomoo. Set it when a proxy doesn't forward the public host and scheme. |
| `MOOMOO_MAX_REQUESTS_PER_SYNC` | `250` | Requests one sync may make before leaving the rest for the next sync. Keep it at least 1, plus 3 per shared trading account and 3 per market each account trades in, with room for retries and extra pages. A sync lists the accounts, reads each account's funds and positions, then each market's fills of today and its recent fills and orders, then each account's recent cash log, and only then older history. A smaller budget runs out at the same step on every sync, so what comes after it never arrives: accounts it doesn't reach keep their last balances, and cash log entries or older history it doesn't reach aren't imported. |
| `MOOMOO_MIN_REQUEST_INTERVAL` | `0.7` | Seconds between the requests of one sync. Raise it if other clients share Sure's IP address. |
| `MOOMOO_MAX_REQUESTS_PER_MINUTE` | `90` | Requests a minute across all moomoo syncs running at once. Lower it if other clients share Sure's IP address. |
| `MOOMOO_HISTORY_DAYS` | `730` | How far back trades and cash log entries are imported (at most 730). |

## What a live account has confirmed

These were checked on a moomoo Singapore universal account:

1. A moomoo Singapore login completes the consent. The account comes back with
   `security_firm` `FUTUSG` and an `enable_market` list that includes Singapore (6), the
   US (2), Hong Kong (1) and China A-shares (4). The login's futures, crypto and other
   accounts are listed too, and Sure shows them as not supported.
2. moomoo accepts `http://localhost:3000` as the callback address.
3. moomoo accepts the `scope` Sure registers with (`trade:read accid:*`) and echoes it
   back; Sure would register again without one if moomoo refused it. The token lists
   `trade:read` and an `accid:` scope for each account ticked on the consent page.
4. Access tokens are renewed with the refresh token as they expire.
5. The funds endpoint honours `currency=SGD` and echoes it back. It lists cash per
   currency as `us_`, `sg_`, `hk_`, `cn_`, `jp_`, `au_`, `my_` and `kr_net_cash_power`,
   which add up to about 99% of `cash` plus `funds_assets`.
6. A US share's position comes back in USD, with `market_val` in that currency. moomoo
   Cash Plus isn't listed among the positions: its money market funds show only in
   `funds_assets` and the cash per currency.
7. `fills_history` and `orders_history` accept explicit 89-day ranges reaching two years
   back. Fills carry `create_time` and `status` but no `updated_time`, so Sure takes the
   copy of a fill it read last as the current one, and reads on past a full window from
   its oldest fill's `create_time`.
8. The cash log writes `created_time` in Singapore time and names each row's currency in
   its running balance (`Balance: 12.34 USD`). Fees are rows of their own, such as
   `Stock Buy Fee`, and so are the dividends of money market funds (`Fund Dividend`) and
   subscriptions to and redemptions from them.

## Unverified assumptions

These still come from moomoo's documentation, which shows only examples for US accounts:

1. moomoo accepts an `https` callback on your own domain. A refused address shows
   moomoo's reason when you click **Connect moomoo**.
2. A cancelled consent comes back with OAuth's `error=access_denied`, and the token
   endpoint reports a dead refresh token as `invalid_grant` (a bare 400 or 401 is
   treated the same way). A refresh repeats the granted `scope`; one that lists none
   keeps the scope Sure has.
3. A refresh token lasts as long as it is used every 14 days (stated for moomoo's MCP
   server, assumed for OpenAPI).
4. Errors may come with HTTP 200 and `"s":"error"` or with a 4xx/5xx status; Sure
   handles both, and treats both HTTP 429 and error `-12011` as a rate limit.
5. Positions cover every market of the account, each with `market_val` in the position's
   own `currency` (seen only for US shares), and funds other than moomoo Cash Plus appear
   as `FUND` positions. `unrealized_pl` is measured against the average cost, as
   in moomoo's OpenD API, so market value less it is the cost of the position. An
   account with no positions returns an empty list or a null `d`.
6. Fill and order history lists the newest rows first, so a window cut short resumes
   from its oldest row, and `deal_id` is unique within an account. moomoo SG fills carry
   no `updated_time`, so Sure assumes their history is listed, and its window filtered,
   by `create_time`. A fill moomoo changes or cancels is listed again with its new
   figures or status in the week each sync re-reads, which on moomoo SG holds only if
   the history follows the time of the change rather than `create_time`. Today's fills
   are read separately, in case the history lags.
7. Singapore codes look like `SG.D05`, Malaysian ones like `BMS.1155`.
8. Error `-12009` means a missing permission. On the account list, or on the balances
   or positions of every shared account, it asks you to reconnect; on one account of
   several, or on trades and cash logs, it is logged and the sync carries on.
9. The cash log outside moomoo SG: the timezone of `created_time`, and whether the
   balance names each row's currency and fees are rows of their own.
10. Funds outside moomoo SG list cash per currency the same way, including money market
    funds, and `cn_` is offshore yuan (CNH). Figures more than 5% apart keep an account
    from being split by currency, and leave one already split at its last balances.

Sync problems are logged under **Settings > Debug** with the source `moomoo`.
