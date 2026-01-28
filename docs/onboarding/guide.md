# Welcome to Sure!

This guide aims to assist new users through:

1. Creating a Sure account
2. Adding your first accounts
3. Recording transactions

This guide also covers the differences between **asset** and **liability** accounts, a key concept for using and understanding balances in Sure!

> [!IMPORTANT]
> Sure is evolving quickly. If you find something inaccurate while following this guide, please:
> 
> - Ask in the [Discord](https://discord.gg/36ZGBsxYEK)
> - Open an [issue](https://github.com/we-promise/sure/issues/new/choose)
> - Or if you know the answer, open a [PR](https://github.com/we-promise/sure/compare)!


## 1. Creating your Sure Account

Once Sure is installed, open a browser and navigate to [localhost:3000](http://localhost:3000/sessions/new).<br />
You will see the **login page** (pictured below). Since we do not have an account yet, click on **Sign Up** to begin. 

<img width="2508" height="1314" alt="Landing page on a fresh install." src="https://github.com/user-attachments/assets/2319dc87-5615-4473-bebc-8360dd983367" />
<br />
<br />

You'll be guided through a short series of screens to set your **login details**, **personal information**, and **preferences**.<br />
When you arrive at the main dashboard, showing **No accounts yet**, you're all set up!

<img width="2508" height="1314" alt="Blank home screen of Sure, with no accounts yet." src="https://github.com/user-attachments/assets/f06ba8e2-f188-4bf9-98a7-fdef724e9b5a" />
<br />
<br />

> [!Note]
> The next sections of this guide cover how to **manually add accounts and transactions** in Sure.<br />
> If you'd like to use an integration with a data provider instead, see:
> 
> - [**Lunch Flow**](https://www.lunchflow.app/)
> - [**Plaid**](/docs/hosting/plaid.md)
> - [**SimpleFIN**](https://beta-bridge.simplefin.org/)
> - [**Enable Banking**](https://enablebanking.com/) (beta)
> - [**CoinStats**](https://coinstats.app/) (beta)
>
> Even if you use an integration, we still recommend reading through this guide to understand **account types** and how they work in Sure.


## 2. Account Types in Sure

Sure supports several account types, which are grouped into **Assets** (things you own) and **Debts/Liabilities** (things you owe):

| Assets      | Debts/Liabilities |
| ----------- | ----------------- |
| Cash        | Credit Card       |
| Investment  | Loan              |
| Crypto      | Other Liability   |
| Property    |                   |
| Vehicle     |                   |
| Other Asset |                   |


## 3. How Asset Accounts Work

Cash, checking and savings accounts **increase** when you add money and **decrease** when you spend money.

Example:

- Starting balance: $500
- Add an expense of $20 -> balance is now $480
- Add an income of $100 -> balance is now $580


## 4. How Debt Accounts Work (Liabilities)

Liability accounts track how much money you **owe**, so the math can feel *backwards* compared to an asset account.

**Key rule:**

- **Positive Balances** = you owe money
- **Negative balances** = the bank owes *you* (e.g. overpayment or refund)

**Transactions behave like this:**

- **Expenses** (e.g. purchases) => increase your debt (you owe more)
- **Payments or refunds** => decrease your debt (you owe less)

Credit Card example:

1. Balance: **$200 owed**
2. Spend $20 => You now owe $220 (balance goes *up* in red)
3. Pay off $50 => You now owe $170 (balance goes *down* in green)

Overpayment Example:

1. Balance: -$44 (bank owes you $44)
2. Spend $1 => Bank now owes you **$43** (balance shown as -$43, moving towards zero)

> [!TIP]
> Why does it work this way? This matches standard accounting and what your credit card provider shows online. Think of a liability balance as "**Amount Owed**", not "available cash."


## 5. Quick Reference: Assets vs. Liability Behavior

| Action           | Asset Account (e.g. Checking) | Liability Account (e.g. Credit Card) |
| ---------------- | ----------------------------- | ------------------------------------ |
| Spend $20        | Balance ↓ $20                 | Balance ↑ $20 (more debt)            |
| Receive $50      | Balance ↑ $50                 | Balance ↓ $50 (less debt)            |
| Negative Balance | Overdraft                     | Bank owes *you* money                |


## 6. Adding Accounts

For this example we'll add a **Savings Account**.<br />

>[!TIP]
>If you're adding a **credit card**, **loan**, or any other **debt**, be sure to select a **Credit Card** or **Liability** account type instead of **Cash**. This will ensure balances update correctly and match what your bank shows.

Most bank accounts (checking, savings, money market) are **Cash Accounts**
1. Click **+ Add Account** → **Cash** → **Enter Account Balance**
2. Fill in details such as:
   - Account name
   - Current Balance
   - Account Subtype (This is where you specify checking, savings, or other)
3. Click **Create Account** when you are ready to proceed.

<img width="500" height="303" alt="Cash Account creation menu" src="https://github.com/user-attachments/assets/e564a447-c85e-403e-979b-efe770ea2a61" />
<br />
<br />

Once created, you'll return to the **Home** screen.<br />
You'll now see:
- Your new cash account in the **Accounts** list (left side)
- An overview of your accounts in the center, under the net worth bar.

To get this bar moving let's add some transactions!

<img width="2508" height="1314" alt="Home screen of Sure, showing one account and no transactions." src="https://github.com/user-attachments/assets/7766a0cd-6b20-48f0-9ba2-87dfddd77236" />

## 7. Adding Transactions

To add a transaction:
1. Go to the **Transactions** page (left sidebar, under **Home**, above **Budgets**)
2. Click **+ New Transaction** (top right)
3. Choose the transaction type:
   - **Expense** → Spending money
   - **Income** → Receiving money
   - **Transfer** → Move money between accounts
4. Enter the details, then click **Add transaction**

You will now see the transaction you added in your **transaction history**, as well as the **net worth chart** updating accordingly.

<img width="500" height="512" alt="Filled-out expense form" src="https://github.com/user-attachments/assets/7c1d38d1-edb8-4d12-8b3e-bbef4836cc92" />

## 8. Managing Investment Accounts

If you're tracking investments in Sure, there are additional features to help you manage your portfolio accurately.

### Cost Basis Tracking

Cost basis tracking helps you understand the original purchase price of your investments, which is essential for calculating returns and tax reporting.

#### Cost Basis Sources

Sure tracks cost basis from three sources:

| Source | Description |
| --- | --- |
| **Manual** | User-entered values that you set directly |
| **Calculated** | Computed from your buy trades and transaction history |
| **Provider** | Imported from your financial institution (Plaid, SimpleFin, etc.) |

#### Priority Hierarchy

When multiple sources provide cost basis data, Sure uses this priority:

**Manual > Calculated > Provider**

This means:
- Manual values always take precedence
- Calculated values override provider data
- Provider data is used when no other source is available

#### Lock Protection

When you manually set a cost basis, Sure automatically locks it to prevent automatic updates from overwriting your value. This ensures your manual entries remain intact during account syncs.

#### Setting Cost Basis Manually

You can set cost basis in two ways:

**From the Holdings List:**

1. Navigate to your investment account
2. Find the holding in your portfolio
3. Click the pencil icon next to the average cost
4. Enter either:
   - **Total cost basis**: The total amount you paid for all shares
   - **Per-share cost**: The average price per share
5. The form automatically converts between total and per-share values
6. Click **Save**

The system will show a confirmation if you're overwriting an existing cost basis.

<img width="531" height="597" alt="image" src="https://github.com/user-attachments/assets/b5a6aafe-de9e-447e-95a6-6000e68fb695" />


**From the Holding Drawer:**

1. Click on a holding to open its detail drawer
2. In the Overview section, click the pencil icon next to "Average Cost"
3. Enter the cost basis (total or per-share)
4. Click **Save**

After saving, you'll see:
- A lock icon indicating the value is protected
- A source label showing "(manual)"

#### Unlocking Cost Basis

If you want to allow automatic updates to recalculate your cost basis:

1. Open the holding drawer
2. Scroll to the **Settings** section
3. Find "Cost basis locked"
4. Click **Unlock**

After unlocking:
- The lock icon disappears
- Future syncs can update the cost basis
- Calculated values (from trades) will replace the manual value

<img width="529" height="231" alt="image" src="https://github.com/user-attachments/assets/89d4c64f-7151-4702-b79f-1e22d47a2bee" />

#### Bidirectional Conversion

The cost basis editor provides real-time conversion between total and per-share values:

- Enter total cost → automatically calculates per-share cost
- Enter per-share cost → automatically calculates total cost

This makes it easy to enter cost basis in whichever format you have available.

### Investment Activity Labels

Activity labels help you classify and understand investment transactions. They appear as badges in your transaction list and can be used to organize and filter your investment activity.

#### Available Activity Types

Sure supports these investment activity labels:

| Label | Description |
| --- | --- |
| **Buy** | Purchase of securities |
| **Sell** | Sale of securities |
| **Contribution** | Money added to the investment account |
| **Withdrawal** | Money removed from the investment account |
| **Dividend** | Dividend payments received |
| **Interest** | Interest earned |
| **Reinvestment** | Dividends or distributions reinvested |
| **Sweep In** | Cash swept into the account |
| **Sweep Out** | Cash swept out of the account |
| **Fee** | Account or transaction fees |
| **Exchange** | Currency or security exchanges |
| **Transfer** | Transfers between accounts |
| **Other** | Miscellaneous transactions |

#### Setting Activity Labels

You can set activity labels in two ways:

**Manually for Individual Transactions:**

1. Open a transaction from an investment or crypto account
2. Scroll to the **Settings** section
3. Find "Activity type"
4. Select a label from the dropdown
5. The change saves automatically

**Automatically with Rules:**

Create rules to automatically label transactions based on patterns:

1. Go to **Settings > Rules**
2. Create a new rule
3. Set conditions (e.g., "IF transaction name contains 'DIVIDEND'")
4. Add action: "Set investment activity label"
5. Choose the label (e.g., "Dividend")
6. Save the rule

<img width="577" height="666" alt="image" src="https://github.com/user-attachments/assets/6660a3cc-af78-4199-8edc-18c198bbaad3" />

Example rules:
- IF name contains "DIVIDEND" THEN set label to "Dividend"
- IF name contains "INTEREST" THEN set label to "Interest"
- IF name contains "FEE" THEN set label to "Fee"

Rules apply automatically to new transactions and can be run on existing transactions.

#### Viewing Activity Labels

Activity labels appear as badges in:
- Transaction lists
- Transaction detail drawers
- Account activity views

They help you quickly identify the nature of each investment transaction without reading the full transaction name.

## 9. Next Steps

Now that you have one account and your first transaction:
- Explore the other account types that Sure offers, adding ones relevant to your finances.
- **Categorize** and **Tag** transactions for better searching and reporting.
- Experiment with **Budgets** to track your spending habits.
- If you have many historical transactions, use **Bulk Import** to load them in.

More detailed user guides for these features are coming soon™.
