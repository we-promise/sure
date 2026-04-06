# Automated Savings Account Interest

This guide explains how to set up automatic interest calculation for deposit accounts (e.g., Trade Republic, savings accounts with a fixed APY).

## How It Works

Sure can automatically calculate and track interest for your savings accounts:

1. **Daily accrual**: Each day, Sure calculates interest based on your current balance and the APY you configure: `balance x (APY / 365)`.
2. **Monthly payout**: On the 1st of each month, Sure creates a transaction with the total interest accrued during the previous month. This transaction is categorized as "Interest" and tagged "auto-generated".

## Setup

### 1. Edit your depository account

Navigate to your savings or checking account and click **Edit**.

### 2. Configure the interest rate

In the edit form, you will see two new fields below the account subtype:

- **Annual Interest Rate (APY %)**: Enter the annual percentage yield. For example, enter `2.75` for a 2.75% APY.
- **Enable automatic interest calculation**: Check this box to activate daily accrual.

Save the account.

### 3. Verify on the Overview tab

Once interest is enabled, your account detail page will show a new **Overview** tab with:

- **Interest Rate**: The APY you configured.
- **Accrued This Month**: Interest accumulated so far in the current month.
- **Total This Year**: Total interest accumulated in the current calendar year.

## Background Jobs

Two Sidekiq cron jobs handle the calculations automatically:

| Job | Schedule | What it does |
|-----|----------|--------------|
| `InterestAccrualJob` | Daily at 3:00 AM UTC | Calculates daily interest for each enabled account and stores an accrual record |
| `InterestPayoutJob` | 1st of each month at 4:00 AM UTC | Sums the previous month's accruals, creates an interest payment transaction, and triggers a balance sync |

Both jobs are **idempotent** — running them multiple times for the same period will not create duplicate records.

## Interest Calculation

The formula used is simple daily interest:

```
daily_interest = account_balance x (APY / 100) / days_in_year
```

- `days_in_year` is 365 (or 366 for leap years).
- The balance used is the account's current balance at the time the daily job runs.
- Interest respects each account's currency.

## Generated Transactions

Monthly interest payment transactions have these properties:

- **Name**: `Interest Payment — {Month} {Year}` (e.g., "Interest Payment — March 2026")
- **Amount**: Negative (income) — the sum of all daily accruals for the month
- **Category**: "Interest" (created automatically if it doesn't exist)
- **Tag**: "auto-generated"

These transactions flow through the normal balance sync, so your account balance will reflect the interest automatically.

## Notes

- Only **depository accounts** (savings, checking, HSA, CD, money market) support this feature.
- The interest rate is a fixed APY — there are no tiered rates or conditional logic.
- You can disable interest at any time by unchecking the toggle. Existing accruals and past transactions are preserved.
- To run the jobs manually (e.g., for testing), use the Rails console:

```ruby
InterestAccrualJob.perform_now   # Accrue today's interest
InterestPayoutJob.perform_now    # Pay out last month's interest
```
