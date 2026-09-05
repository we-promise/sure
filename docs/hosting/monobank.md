# Setting Up monobank (Ukraine)

[monobank](https://monobank.ua) exposes a personal API that returns your own cards, jars
and statements. You bring your own token, so Sure talks to monobank directly on your
behalf — no third-party aggregator sits in between.

> [!NOTE]
> This integration uses monobank's **personal** API. Its documentation states that a
> service which stores other people's data on its own servers must use the corporate
> (service provider) API instead, and that programs used by clients personally — where
> the data never passes through the developer's nodes — do not. A self-hosted Sure
> instance is the latter. If you run Sure as a hosted service for other people, read
> [monobank's API terms](https://api.monobank.ua/docs/index.html) first.

> [!NOTE]
> The personal API is not available to clients under 16. Data for a child's accounts is
> available from the parent's account.

## 1. Get Your Personal Token

1. Go to [api.monobank.ua](https://api.monobank.ua/).
2. Sign in by scanning the QR code with the monobank app.
3. Generate a personal token and copy it. **It is shown only once.**

The token is scoped to your own data: it can list your accounts, read statements, and
register a statement webhook (`POST /personal/webhook`). It cannot move money.

## 2. Add monobank to Sure

1. In Sure, go to **Settings > Providers** and find the **monobank** panel.
2. Paste your token and save.
3. Your cards and jars appear for setup. Link each one to an existing Sure account or
   create a new account from it, and skip anything you don't want to track.

Cards become cash accounts; jars become savings accounts. A card's balance is stored as
your own funds — monobank reports the credit limit inside the balance, and Sure
subtracts it.

## 3. Syncing

monobank's rate limit shapes how syncing works. Each personal endpoint accepts **one
request per minute**, and a single statement request may cover at most **31 days**. So:

- Every sync fetches your account list once, then reads statements account by account.
- A sync spends a fixed budget of statement requests (4 by default). Accounts that don't
  fit are picked up by the next sync, least-recently-synced first.
- History older than one statement window is backfilled over successive syncs, walking
  backwards 31 days at a time until it reaches the start date.
- Each sync also re-reads the last few days, and any older hold that is still
  unsettled, so pending transactions stay accurate.

Because of the throttle, a sync sleeps between requests: with four accounts, expect it
to take a few minutes. Transactions are deduplicated by their monobank id, so
re-syncing never creates duplicates.

### Pending transactions

Held (unsettled) authorizations are imported and marked **Pending**. When a hold
settles, monobank may issue the settled record under a different id, so the settled
record is matched to the pending entry by amount and date, and inherits it.

A hold that simply disappears from the statement — cancelled rather than settled — has
its pending entry removed. Two things are never removed:

- A hold the statement request did not actually reach, so it stays visible while the
  funds are still blocked. Pre-authorizations for hotels, car hire and fuel routinely
  outlive the few days a sync re-reads by default.
- An entry you have taken over yourself (excluded, edited, or split). It only loses its
  pending badge, so your edits, splits and transfers survive.

To import only settled transactions:

```
MONOBANK_INCLUDE_PENDING=0
```

### Categories

monobank does not categorise transactions; it reports the merchant's MCC. Sure maps the
codes with a clear equivalent (groceries, restaurants, fuel, pharmacies, …) onto your
existing categories, matching them by the name in your own language. Codes without an
honest equivalent — cash withdrawals, transfers, gambling — are left uncategorised for
your own rules to handle.

### Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `MONOBANK_INCLUDE_PENDING` | `1` | Import held transactions and badge them as pending. |
| `MONOBANK_MAX_STATEMENT_REQUESTS_PER_SYNC` | `4` | Statement requests one sync may spend. Each costs about a minute. |
| `MONOBANK_PENDING_LOOKBACK_DAYS` | `3` | Minimum period every sync re-reads. A hold older than this extends the window on its own. |
| `MONOBANK_INITIAL_HISTORY_DAYS` | `31` | History a new connection reaches for when no start date is set. |
| `MONOBANK_MIN_REQUEST_INTERVAL` | `60` | Seconds enforced between requests to the same endpoint. |
| `MONOBANK_DEBUG_RAW` | unset | Log raw API payloads. Development only — the dump contains personal data. |

## Troubleshooting

**Connection requires update**
The token was revoked or is invalid. Generate a new one at
[api.monobank.ua](https://api.monobank.ua/) and update it in the provider panel.

**A sync says accounts were skipped**
Either the statement request budget ran out for this run, or monobank throttled the
request — one request per minute per endpoint, so a manual sync started right after a
scheduled one collides. All of these are normal and leave the connection healthy: the
next sync continues where this one stopped. Raise
`MONOBANK_MAX_STATEMENT_REQUESTS_PER_SYNC` if you would rather trade a longer sync for
fewer runs.

**Older transactions are missing**
History arrives in 31-day steps, one step per sync. Set a start date on the connection
to bound how far back it goes, then let it run.

**Sync errors**
Provider sync failures and notes are captured in Sure's debug log (super admin:
**Settings > Debug**), filtered by the `monobank` provider key.
