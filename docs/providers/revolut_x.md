# Setting Up Revolut X (Crypto Exchange)

[Revolut X](https://exchange.revolut.com) is Revolut's crypto exchange. Sure syncs it read-only: it imports balances, holdings and transaction history, and never trades.

> [!NOTE]
> Revolut X support is in beta. Only **admin** users can connect a provider.

## 1. Create the Connection in Sure

1. In Sure, go to **Settings > Providers** and open the **Revolut X** panel.
2. Enter a connection name. Each Revolut X sub-account needs its own API key, and so its own connection: name it after the sub-account.
3. Choose how the connection gets its signing key:
   - **Let Sure create it (recommended):** leave **Existing private key** blank. Sure generates an Ed25519 key pair and keeps the private key encrypted. It is never shown again.
   - **Bring your own key:** paste an existing Ed25519 private key in PEM format into **Existing private key**. Sure rejects any other key type.
4. Click **Add Revolut X connection**. The connection now waits for its API key and shows its **public key**.

## 2. Register the Public Key in Revolut X

1. Copy the public key from the connection in Sure (**Copy public key**).
2. Open the Revolut X web app and go to **Profile > API keys**.
3. Add a new API key and paste the public key when Revolut X asks for it.
4. Revolut X shows a 64-character API key. Copy it.

> [!TIP]
> If Revolut X asks for an IP allow-list for the key, add the public IP address of your Sure server. Requests from other addresses are rejected with a 401 error.

## 3. Add the API Key to Sure

1. Back in Sure, paste the API key into the connection and click **Save**. The first sync starts right away.
2. Once it finishes, use **Setup account** (or **Import Account** on the Accounts page) to import the connection as a Crypto exchange account. You can also link it to an existing manual Crypto exchange account instead.

To connect another sub-account, add another connection and repeat these steps with that sub-account's API key.

## What Is Synced

- **One account per connection.** Each connection becomes one Crypto account (subtype exchange), named after the connection.
- **Balances.** Each crypto balance uses its `total`, which includes staked and reserved coins. It becomes a holding priced from Revolut X public tickers. Fiat balances become the account's cash.
- **History.** The first sync walks back in windows of at most 30 days to the earliest sub-account creation date (or the connection's sync start date, when it has one). Each window costs one rate-limit token per day it covers. Later syncs re-read the last 3 days plus any rows that were still pending. When Revolut X answers `429 Too Many Requests`, Sure waits for the `Retry-After` time and continues.
- **How transactions are recorded:**
  - **Buy / sell:** a trade. When the money came from or went to your Revolut account, Sure also records a cash transfer in or out.
  - **Receive / send:** a transfer in or out.
  - **Stake / unstake:** no entry. Staked coins are already part of the balance.
  - **Reward:** income, labelled Dividend.
- **Pending activity.** Fiat movements show as pending until they complete. Crypto movements appear once they are completed. Cancelled, failed and reverted rows are skipped, or removed if they were imported earlier.

## Limits

- **Fees are not itemized.** The Revolut X transaction list reports net amounts only.
- **One API key per sub-account.** A Revolut X API key only sees its own sub-account.

## Read-Only by Design

Sure's Revolut X client only sends signed `GET` requests. It never calls the order, cancel, replace or RFQ endpoints, so a Sure connection cannot place, change or cancel trades, whatever the key allows.

## Troubleshooting

**Connection says "Waiting for API key"**
The API key has not been saved yet. Finish steps 2 and 3.

**Connection says "Credentials need updating"**
Revolut X rejected the API key. Check that the key is still active in Revolut X, that it was created for this connection's public key, and that your server's IP is allowed if you set an allow-list. Then paste the key into the connection again.

**Replacing the private key**
A connection's private key can be replaced from its panel. The old API key stops working with the new key, so register the new public key in Revolut X and save the new API key as well.

**Sync errors**
Provider sync failures and unpriced assets are captured in Sure's debug log (super admin: **Settings > Debug**).
