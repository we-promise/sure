---
title: "fix: Installment Payment Transaction Type for Reports"
type: fix
date: 2026-01-22
---

# fix: Installment Payment Transaction Type for Reports

## Overview

Installment payment transactions currently use `funds_movement` kind, which **excludes them from budget/expense reports**. Users expect loan payments to appear in their financial reports while also reducing the loan balance. The fix is to change the transaction kind to `loan_payment`, which is specifically designed for this purpose.

## Problem Statement

**Current behavior:** Installment payments use `kind: "funds_movement"` (set in `Installment::Creator`), which is excluded from income statements and budget analytics per the report filtering logic.

**Expected behavior:** Installment payments should appear as expenses in reports (like other loan payments) while still reducing the loan balance.

**Root cause:** `Installment::Creator` uses `funds_movement` (line 33), but `Transfer::Creator` correctly uses `loan_payment` for loan accounts (lines 77-78). This inconsistency means installment payments behave differently from manual loan payments.

## Proposed Solution

Change the transaction kind from `funds_movement` to `loan_payment` in the Installment::Creator. This aligns with:
1. The existing `Transfer::Creator` behavior for loan accounts
2. The transaction kind enum documentation: "loan_payment: A payment to a Loan account, treated as an expense in budgets"
3. The income statement filtering logic that includes `loan_payment` but excludes `funds_movement`

## Technical Approach

### Key Files

| File | Change |
|------|--------|
| `app/models/installment/creator.rb:33` | Change `kind: "funds_movement"` to `kind: "loan_payment"` |
| `test/models/installment_test.rb` | Update existing test, add report inclusion test |
| Migration (new) | Update existing installment transactions |

### Transaction Kind Reference

From `app/models/transaction.rb:14-21`:
```ruby
enum :kind, {
  standard: "standard",           # Included in budget analytics
  funds_movement: "funds_movement", # EXCLUDED from budget analytics
  cc_payment: "cc_payment",       # EXCLUDED from budget analytics
  loan_payment: "loan_payment",   # INCLUDED as expense in budgets <-- USE THIS
  one_time: "one_time",           # EXCLUDED from budget analytics
  investment_contribution: "investment_contribution"
}
```

### Report Inclusion Logic

From `app/models/income_statement/totals.rb:72`:
```sql
WHERE at.kind NOT IN ('funds_movement', 'one_time', 'cc_payment')
```

Note: `loan_payment` is NOT in this exclusion list, so it WILL appear in reports.

## Acceptance Criteria

- [x] Installment payment transactions use `loan_payment` kind
- [x] New installment payments appear in income statement/budget reports
- [x] Existing installment transactions are migrated to `loan_payment` kind
- [x] Loan balance still decreases correctly when payments are made
- [x] Tests verify report inclusion for installment payments

## MVP Implementation

### app/models/installment/creator.rb

```ruby
# Change line 33 from:
kind: "funds_movement"

# To:
kind: "loan_payment"
```

### db/migrate/YYYYMMDDHHMMSS_update_installment_transactions_to_loan_payment.rb

```ruby
class UpdateInstallmentTransactionsToLoanPayment < ActiveRecord::Migration[7.2]
  def up
    execute <<-SQL
      UPDATE transactions
      SET kind = 'loan_payment'
      WHERE extra->>'installment_id' IS NOT NULL
        AND kind = 'funds_movement'
    SQL
  end

  def down
    execute <<-SQL
      UPDATE transactions
      SET kind = 'funds_movement'
      WHERE extra->>'installment_id' IS NOT NULL
        AND kind = 'loan_payment'
    SQL
  end
end
```

### test/models/installment_test.rb

```ruby
test "installment payment transactions use loan_payment kind for report inclusion" do
  account = accounts(:loan)
  installment = Installment.create!(
    account: account,
    installment_cost: 100,
    total_term: 12,
    current_term: 0,
    first_payment_date: 6.months.ago.to_date,
    payment_period: "monthly"
  )

  Installment::Creator.new(installment: installment).create_historical_transactions

  transactions = account.transactions.where("extra->>'installment_id' = ?", installment.id.to_s)

  assert transactions.any?, "Expected installment transactions to be created"
  assert transactions.all? { |t| t.loan_payment? }, "Expected all transactions to be loan_payment kind"

  # Verify these would be included in reports (not in exclusion list)
  excluded_kinds = %w[funds_movement one_time cc_payment]
  assert transactions.none? { |t| excluded_kinds.include?(t.kind) }
end
```

## References

### Internal References
- Transaction kinds: `app/models/transaction.rb:14-21`
- Transfer::Creator loan_payment logic: `app/models/transfer/creator.rb:77-78`
- Installment::Creator current implementation: `app/models/installment/creator.rb:33`
- Income statement exclusions: `app/models/income_statement/totals.rb:72`
- Demo loan payment pattern: `app/models/demo/generator.rb:1009-1014`

### Related Work
- Current branch: `Installment-detail-page-improvement`
- Recent commit: `8b4d87c1` (set installment transaction kind to funds_movement)
