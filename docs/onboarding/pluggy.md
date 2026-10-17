# Connecting Your Bank with Pluggy

[Pluggy](https://pluggy.ai) is a banking and investment aggregator for Latin America. Connect it to Sure to automatically sync your **transactions**, **balances**, and **investment holdings**.

> [!NOTE]
> Pluggy focuses on Latin-American institutions (Brazil in particular). For banks outside LatAm, see [Plaid](/docs/hosting/plaid.md) instead.

> [!IMPORTANT]
> Setting up and linking data providers is an **admin** action. If you're not an admin, ask your Sure administrator to configure Pluggy first.

## 1. Get your Pluggy credentials

1. Open the [Pluggy](https://pluggy.ai) to sign in and connect your bank.
2. Go to the [application section](https://dashboard.pluggy.ai/applications) and copy your **Client** (`client_id`) and **Client Secret** (`client_secret`).

## 2. Configure Pluggy in Settings

1. In Sure, open **Settings → Providers**.
2. Scroll to the **Pluggy** panel.
3. Paste your **Client** and **Client Secret** into the credential fields.
4. Click **Save Configuration**.

A status dot in the panel tracks progress:

- ⚪ **Not configured** — no credentials yet
- 🟡 **Credentials saved. Finish bank connection in Pluggy Connect** — credentials stored, bank not yet linked
- 🟢 **Connected and ready to sync** — bank linked, ready to import accounts

Credentials are stored **encrypted** on your Sure instance; only an admin can update them.

## 3. Connect your bank (Pluggy Connect)

1. In the Pluggy panel, after saving credentials, a **Connect via Pluggy Widget** box appears. Click **Open Pluggy Connect**.
2. A new window opens — authenticate with your bank through Pluggy and choose the accounts you want to share.
3. When the widget completes, open the **Accounts** tab. Newly imported accounts appear with a **Set Up New Accounts** prompt.

> [!NOTE]
> If **Open Pluggy Connect** doesn't appear, or a sync keeps failing, restart the item on your Pluggy dashboard (delete and reconnect it), then try again.

## 4. Set up your imported accounts

Imported Pluggy accounts need an account type before they're added to Sure.

1. Click **Set Up New Accounts** on the connection.
2. For each account, an **Account Type** is detected automatically — adjust it if needed:

   | Account type | Example subtypes |
   | --- | --- |
   | Checking or Savings Account | Checking, Savings, HSA, Certificate of Deposit, Money Market |
   | Credit Card | _(none)_ |
   | Loan or Mortgage | Mortgage, Student Loan, Auto Loan, Other Loan |
   | Investment Account | _(none)_ |
   | Other Asset | _(none)_ |

   You can also **Skip this account** to leave it un-imported.
3. Set the **Historical Data Range** to choose how far back Sure syncs transactions.
4. Click **Create Accounts**.

> [!NOTE]
> Pluggy accounts that have **no name configured in Pluggy** can't be imported. If one shows "Cannot import — please configure account name in Pluggy," open the Pluggy dashboard, set a name for the account, and sync again.

## 5. After setup

- **Transactions and balances sync automatically** for linked accounts going forward.
- **Investment accounts** import holdings; Sure calculates the balance from them.
- **Pending transactions** are fetched by default and shown with a "Pending" badge.

### Managing a Pluggy connection

From an account's menu (⋮):

- **Edit** — rename the account or adjust details. Your custom name persists across syncs; Pluggy only updates the underlying connection, never your Sure account's display name.
- **Change Pluggy account** — relink to a different Pluggy account (for example, a replaced card).
- **Unlink provider** — convert the account to a manual account. Existing transactions and balances are kept.

From **Settings → Providers → Pluggy**:

- **Update Configuration** to change your `client_id` / `client_secret`.
- Re-open **Pluggy Connect** to reconnect when a connection needs re-authentication.

---

← Back to the [Onboarding Guide](/docs/onboarding/guide.md)
