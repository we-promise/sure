# Welcome to Sure!

This guide aims to assist new users through:

1. Creating a Sure account
2. Adding your first accounts
3. Recording transactions

This guide also covers the differences between **asset** and **liability** accounts, a key concept for using and understanding balances in Sure!

> [!IMPORTANT]
> Sure is evolving quickly. If you find something innacurate while following this guide, please:
> 
> - Ask in the [Discord](https://discord.gg/36ZGBsxYEK)
> - Open an [issue](https://github.com/we-promise/sure/issues/new/choose)
> - Or if you know the anser, open a [PR](https://github.com/we-promise/sure/compare)!


## 1. Creating your Sure Account

Once Sure is installed, open a browser and navigate to [localhost:3000](http://localhost:3000/sessions/new).<br />
You will see the **login page** (pictured below). Since we do not have an account yet, click on **Sign Up** to begin. 

<img width="2508" height="1314" alt="Landing page on a fresh install." src="https://github.com/user-attachments/assets/2319dc87-5615-4473-bebc-8360dd983367" />
<br />
<br />

You’ll be guided through a short series of screens to set your **login details**, **personal information**, and **preferences**.<br />
When you arrive at the main dashboard, showing **No accounts yet**, you’re all set up!

<img width="2508" height="1314" alt="Blank screen of Sure, with no accounts yet." src="https://github.com/user-attachments/assets/f06ba8e2-f188-4bf9-98a7-fdef724e9b5a" />
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


## 2. Accout Types in Sure

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

- **Expenses** (negative amounts) => increase your debt (you owe more)
- **Payments or refunds** (positive amounts) => decrease your debt (you owe less)

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
| Spend $20        | Balance ↓ $20                 | Balance ↑ $20 (more debt)            |
| Receive $50      | Balance ↑ $50                 | Balance ↓ $50 (less debt)            |
| Negative Balance | Overdraft                     | Bank owes *you* money                |


## 6. Adding Transactions

*(To be added )*






