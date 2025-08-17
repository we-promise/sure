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

You’ll be guided through a short series of screens to set your **login details**, **personal information**, and **preferences**.<br />
When you arrive at the main dashboard, showing **No accounts yet**, you’re all set up!

<img width="2508" height="1314" alt="Blank home screen of Sure, with no accounts yet." src="https://github.com/user-attachments/assets/f06ba8e2-f188-4bf9-98a7-fdef724e9b5a" />
<br />
<br />

> [!Note]
> The next sections of this guide cover how to **manually add accounts and transactions** in Sure.<br />
> If you’d like to use an integration with a data provider instead, see:
> 
> - **Lunch Flow** (WIP)
> - [**Plaid**](/docs/hosting/plaid.md)
> - **SimpleFin** (WIP)
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
>If you’re adding a **credit card**, **loan**, or any other **debt**, be sure to select a **Credit Card** or **Liability** account type instead of **Cash**. This will ensure balances update correctly and match what your bank shows.

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

## 8. Next Steps

Now that you have one account and your first transaction:
- Explore the other account types that Sure offers, adding ones relevant to your finances.
- **Categorize** and **Tag** transactions for better searching and reporting.
- Experiment with **Budgets** to track your spending habits.
- If you have many historical transactions, use **Bulk Import** to load them in.

More detailed user guides for these features are coming soon™.
