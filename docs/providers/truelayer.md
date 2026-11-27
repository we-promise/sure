# Setting Up TrueLayer (UK)

[TrueLayer](https://truelayer.com) is a UK Open Banking provider. Its Data API reads
current accounts, savings accounts and credit cards from most UK banks and card
issuers. You bring your own TrueLayer app, so Sure talks to TrueLayer directly with
your credentials.

## 1. Create a TrueLayer App

1. Sign up at [console.truelayer.com](https://console.truelayer.com) and create an app.
2. Copy its **client ID** and **client secret**.
3. Under **Allowed redirect URIs**, add the callback URL shown in Sure's TrueLayer panel.
   It is `https://<your-sure-host>/truelayer_items/callback`, and must match exactly.
   TrueLayer accepts plain `http` only for `localhost`, so a public instance needs HTTPS.

A client ID starting with `sandbox-` uses TrueLayer's sandbox, which offers the
**Mock Bank** provider for trying things out without a real account.

## 2. Connect a Bank

1. In Sure, go to **Settings > Providers** and open the **TrueLayer** panel.
2. Save the client ID and secret, then click **Connect a bank**.
3. Pick your bank at TrueLayer and approve access in your bank's app or website.
4. Back in Sure, the bank's accounts and cards are imported. Use **Set Up New Accounts**
   on the Accounts page to choose an account type for each, or skip the ones you don't
   want. You can also link one to an existing manual account from that account's page.

Each bank you connect is a separate connection with its own consent. Connect more banks
with **Connect a bank** again.

## 3. History and Syncing

UK banks release more than 90 days of history only while you are present, which in
practice means the few minutes after you approve access. Straight after a bank is
connected, Sure fetches history a year at a time, back to `TRUELAYER_BACKFILL_YEARS`
(default 7), until the bank refuses an older range. Set up the imported accounts
within a few minutes of approving access if you want the full history. If the first
import only runs after that window, the connection card says so and offers
**Reconnect**, which opens a new one.

The setup dialog has an **Import transactions from** date. Leave it blank to keep
everything the bank provided, or set it to leave older transactions out; later syncs
and backfills don't fetch before it either.

After that, syncs read the linked accounts only, from a week before the last sync and
never more than 89 days back. Unattended access is rate limited (often about four
requests per endpoint per day), so a rate-limited request is not retried.

Transactions are matched by TrueLayer's stable transaction id, so re-syncing never
creates duplicates. Card charges are imported as spending and refunds as income.
Pending transactions are not imported; they appear once they are booked.

## 4. Reconnecting

UK Open Banking consent lasts 90 days. Sure shows the expiry date in the TrueLayer
panel and a **Reconnect** button from two weeks before it lapses, or straight away if
the bank revokes access. Reconnecting keeps the same TrueLayer account ids, so linked
accounts keep their history.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `TRUELAYER_REDIRECT_URI` | derived from the request | Callback URL sent to TrueLayer. Set it when a proxy doesn't forward the public host and scheme. |
| `TRUELAYER_BACKFILL_YEARS` | `7` | Years of history fetched straight after a bank is connected (1–20). |
