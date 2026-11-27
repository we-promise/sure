# Setting Up Redbark (Australian Banks)

[Redbark](https://redbark.com) connects Australian bank accounts to Sure through the [Consumer Data Right](https://www.cdr.gov.au/) (CDR) open banking framework. Data flows one way, from your banks into Sure, using read-only consented access.

> [!NOTE]
> Redbark covers Australian institutions (banks under the CDR regime). If you're outside Australia, see the other provider integrations in the [onboarding guide](/docs/onboarding/guide.md).

## 1. Create Your Redbark Account

1. Go to [app.redbark.com](https://app.redbark.com) and sign up.
2. Connect your bank accounts. You'll be taken through your bank's official consent flow, so Redbark never sees your bank login.

## 2. Create an API Key

> [!NOTE]
> API access requires a Redbark Developer or Professional plan. It is not available on the Saver plan.

1. In Redbark, go to **Settings > API Keys**.
2. Create a new key and copy it. It is only shown once.

## 3. Add Redbark to Sure

1. In Sure, go to **Settings > Providers** and find the **Redbark** panel.
2. Paste your API key and save.
3. Your connected bank accounts will appear for setup. Link each one to an existing Sure account or create a new account from it. Accounts you don't want in Sure can be skipped.

## 4. Syncing

- The first sync pulls 90 days of history for each linked account (or from the start date you pick during setup).
- Later syncs are incremental, with a 7 day lookback to catch late-posting transactions.
- Balances come from your bank via Redbark on every sync.
- Transactions are deduplicated by their Redbark transaction id, so re-syncing never creates duplicates.

### Pending transactions

By default only posted transactions are imported. To also import pending transactions, set:

```
REDBARK_INCLUDE_PENDING=true
```

When a pending transaction settles, the posted version replaces it automatically.

## Troubleshooting

**Connection requires update**
Your API key was revoked or expired. Create a new key in Redbark and update it in the Sure provider panel.

**An account is missing**
Only banking accounts are synced. Brokerage accounts connected to Redbark are not imported by this integration. Also check the account's consent is still active in Redbark under **Settings > Consents**.

**Sync errors**
Provider sync failures are captured in Sure's debug log (super admin: **Settings > Debug**), including counts of skipped and failed rows.
