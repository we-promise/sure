---
title: "Promote Installment to First-Class Accountable Type"
type: refactor
date: 2026-01-24
---

# Promote Installment to First-Class Accountable Type

## Overview

Promote `Installment` from a secondary model nested under `Loan` (via `has_one :installment`) to its own first-class accountable type (`accountable_type: "Installment"`, classification: `"liability"`). This separates two fundamentally different financial products — amortizing loans with interest vs. fixed-payment schedules without interest — giving each clean, independent extensibility.

## Problem Statement

The current architecture couples installments into the Loan model via a dual-mode pattern:

1. **`LoansController`** handles both standard loans and installments via `create_with_installment` / `update_with_installment`
2. **The Loan form** (`app/views/loans/_form.html.erb`) switches between two completely different field sets based on `params[:installment]`
3. **The Account model** has installment-specific helpers (`installment_subtype?`, `calculated_balance`, `remaining_principal_money`) mixed into a model that serves all account types
4. **The overview tab** (`loans/tabs/_overview.html.erb`) conditionally renders different content for installment-mode vs. standard loans

This makes both features harder to extend independently. Adding installment-specific features (analytics, notifications, payment tracking) requires touching Loan code and risking regressions.

## Proposed Solution

Create `Installment` as a standalone accountable type by **repurposing the existing `installments` table** as the accountable backing table. The table already contains all schedule data — we flip the relationship direction from `Installment belongs_to :account` to `Account belongs_to :accountable (Installment)` via `delegated_type`.

## Technical Approach

### Table Strategy

The existing `installments` table has: `installment_cost`, `total_term`, `current_term`, `payment_period`, `first_payment_date`, `most_recent_payment_date`. Under `delegated_type`, the `accounts` table stores `accountable_type: "Installment"` and `accountable_id` pointing to a row in the `installments` table.

Changes to the table:
- **Remove** `account_id` FK (relationship reverses under delegated_type)
- **Keep** all schedule columns in place
- **Add** standard accountable columns (`subtype`, `locked_attributes`)

After the change, the Installment model gains `has_one :account, as: :accountable` (provided by the `Accountable` concern), so `installment.account` continues to work — just from the opposite direction.

---

## Implementation

### 1. Database Migration (Single Atomic Migration)

File: `db/migrate/XXXXXX_promote_installment_to_accountable_type.rb`

All schema changes, data migration, and cleanup in one migration to avoid inconsistent intermediate states.

```ruby
class PromoteInstallmentToAccountableType < ActiveRecord::Migration[7.2]
  def up
    # Step 1: Update classification generated column
    # Use a single DDL statement to avoid a window where classification queries fail
    execute <<-SQL
      ALTER TABLE accounts
        DROP COLUMN classification,
        ADD COLUMN classification text GENERATED ALWAYS AS (
          CASE
            WHEN accountable_type IN ('Loan', 'CreditCard', 'OtherLiability', 'Installment')
            THEN 'liability'
            ELSE 'asset'
          END
        ) STORED;
    SQL

    # Step 2: Safety assertion — each account should have at most 1 installment
    count = execute(<<-SQL).first["cnt"]
      SELECT COUNT(*) as cnt FROM (
        SELECT account_id, COUNT(*) as c
        FROM installments
        GROUP BY account_id
        HAVING COUNT(*) > 1
      ) dupes;
    SQL
    raise "Found accounts with multiple installments — fix data first" if count.to_i > 0

    # Step 3: Data migration — convert installment-mode loans to new type
    # (while account_id FK still exists on installments table)
    execute <<-SQL
      UPDATE accounts
      SET accountable_type = 'Installment',
          accountable_id = installments.id,
          subtype = NULL
      FROM installments
      WHERE installments.account_id = accounts.id
        AND accounts.accountable_type = 'Loan'
        AND accounts.subtype = 'installment';
    SQL

    # Step 4: Clean up orphaned Loan records
    execute <<-SQL
      DELETE FROM loans
      WHERE NOT EXISTS (
        SELECT 1 FROM accounts
        WHERE accounts.accountable_type = 'Loan'
          AND accounts.accountable_id = loans.id
      );
    SQL

    # Step 5: Restructure installments table for accountable pattern
    remove_foreign_key :installments, :accounts
    remove_index :installments, :account_id
    remove_column :installments, :account_id, :uuid
    add_column :installments, :subtype, :string
    add_column :installments, :locked_attributes, :jsonb, default: {}
  end

  def down
    # Add account_id back
    add_reference :installments, :account, type: :uuid, foreign_key: true, index: true
    remove_column :installments, :subtype
    remove_column :installments, :locked_attributes

    # Repopulate account_id from accounts table
    execute <<-SQL
      UPDATE installments
      SET account_id = accounts.id
      FROM accounts
      WHERE accounts.accountable_type = 'Installment'
        AND accounts.accountable_id = installments.id;
    SQL

    # Revert accountable_type back to Loan
    execute <<-SQL
      UPDATE accounts
      SET accountable_type = 'Loan',
          subtype = 'installment'
      WHERE accountable_type = 'Installment';
    SQL

    # Restore classification column without Installment
    execute <<-SQL
      ALTER TABLE accounts
        DROP COLUMN classification,
        ADD COLUMN classification text GENERATED ALWAYS AS (
          CASE
            WHEN accountable_type IN ('Loan', 'CreditCard', 'OtherLiability')
            THEN 'liability'
            ELSE 'asset'
          END
        ) STORED;
    SQL
  end
end
```

---

### 2. Model Changes

**2.1. Rewrite `Installment` model as accountable type**

File: `app/models/installment.rb`

```ruby
class Installment < ApplicationRecord
  include Accountable

  has_many :recurring_transactions, dependent: :destroy

  SUBTYPES = {}.freeze

  class << self
    def color
      "#F59E0B"
    end

    def icon
      "calendar-check"
    end

    def classification
      "liability"
    end
  end

  # Keep all existing schedule methods:
  # generate_payment_schedule, calculate_current_balance,
  # remaining_principal_money, next_payment_date,
  # payments_scheduled_to_date, payments_completed, etc.

  # Remove: belongs_to :account
  # Remove: after_create :ensure_account_subtype
  # Remove: after_destroy :clear_account_subtype
  # Note: installment.account now works via Accountable concern's
  #        has_one :account, as: :accountable
end
```

**2.2. Update `Accountable` concern**

File: `app/models/concerns/accountable.rb`

Add `"Installment"` to the TYPES array:
```ruby
TYPES = %w[Depository Investment Crypto Property Vehicle OtherAsset CreditCard Loan Installment OtherLiability]
```

**2.3. Update `Account` model**

File: `app/models/account.rb`

- Remove `has_one :installment, dependent: :destroy`
- Remove `installment_subtype?` method
- Remove installment-specific `calculated_balance` and `remaining_principal_money` delegations
- Remove installment-specific `short_subtype_label` / `long_subtype_label` overrides
- Update `balance_type`:

```ruby
def balance_type
  case accountable_type
  when "Loan", "OtherLiability", "Property", "Vehicle", "OtherAsset", "Installment"
    :non_cash
  when "Depository", "CreditCard"
    :cash
  when "Investment", "Crypto"
    :investment
  else
    raise "Unknown account type: #{accountable_type}"
  end
end
```

- **Audit all other `accountable_type` switches** in the Account model for: `favorable_direction`, `balance_display_name`, `opening_balance_display_name`, and any provider-specific conditionals. Add `"Installment"` where appropriate (typically alongside `"Loan"`).

**2.4. Update `Balance::BaseCalculator`**

File: `app/models/balance/base_calculator.rb` (lines 73, 106)

Replace `account.accountable_type == "Loan"` with:
```ruby
account.accountable_type.in?(%w[Loan Installment])
```

**2.5. Update `Transfer::Creator`**

File: `app/models/transfer/creator.rb`

```ruby
def outflow_transaction_kind
  if destination_account.loan? || destination_account.installment?
    "loan_payment"
  # ...
```

**2.6. Update `Transfer` model**

File: `app/models/transfer.rb`

Replace `to_account&.accountable_type == "Loan"` with:
```ruby
to_account&.accountable_type.in?(%w[Loan Installment])
```

**2.7. Update `Installment::Creator`**

File: `app/models/installment/creator.rb`

The `Accountable` concern provides `has_one :account, as: :accountable`, so `installment.account` continues to work. Update any references that used the old `belongs_to` direction — they should now work identically via the concern's inverse.

**2.8. Update provider balance handling**

File: `app/models/account.rb` (line ~134)

Add `"Installment"` to the absolute-value balance check:
```ruby
if account_type.in?(%w[CreditCard Loan Installment])
```

---

### 3. Controller & Routes

**3.1. Create `InstallmentsController`**

File: `app/controllers/installments_controller.rb`

```ruby
class InstallmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes(
    :id, :installment_cost, :total_term, :current_term,
    :payment_period, :first_payment_date, :subtype
  )

  def create
    # Build account with Installment accountable
    # Run Installment::Creator for payment generation
    # Handle source_account_id for recurring payment
  end

  def update
    # Detect schedule changes
    # If changed: remove old activity, re-run Creator
    # Update balance
  end

  private

  def set_link_options
    @provider_configs = []  # No provider linking for installments
  end
end
```

**3.2. Add route**

File: `config/routes.rb`

```ruby
resources :installments, only: %i[new create edit update]
```

**3.3. Clean up `LoansController`**

File: `app/controllers/loans_controller.rb`

Remove all installment-mode logic:
- `create_with_installment`
- `update_with_installment`
- `installment_mode?`
- `installment_params`
- The `create`, `update`, and `new` overrides

The controller reverts to pure `AccountableResource` behavior.

---

### 4. Views & Components

**4.1. Create installment form**

File: `app/views/installments/_form.html.erb`

Dedicated form with installment-relevant fields only: name, installment cost, total term, payment period, current term, payment day, first payment date (calculated), balances (calculated/disabled), source account selector.

Use `data-controller="loan-form"` — the existing `loan_form_controller.js` already has all the balance calculation and first payment date logic needed. No new Stimulus controller required.

**4.2. Create installment overview tab**

File: `app/views/installments/tabs/_overview.html.erb`

Display: `Installments::OverviewComponent`, `Installments::PaymentScheduleComponent`, summary cards, edit link.

**4.3. Update `UI::AccountPage` tabs**

File: `app/components/UI/account_page.rb`

```ruby
when "Property", "Vehicle", "Loan", "Installment"
  [:activity, :overview]
```

**4.4. Update "new account" UI**

File: `app/views/accounts/new.html.erb`

Change Installment link from `new_loan_path(installment: "true")` to `new_installment_path(step: "method_select")`.

**4.5. Update accountable group sidebar**

File: `app/views/accounts/_accountable_group.html.erb`

Update `account_group.key == "installment"` routing to `new_installment_path`.

**4.6. Clean up Loan form**

File: `app/views/loans/_form.html.erb`

Remove entire installment-mode conditional block. Keep only standard loan fields.

**4.7. Clean up Loan overview tab**

File: `app/views/loans/tabs/_overview.html.erb`

Remove installment-conditional rendering. Show only loan-specific cards.

**4.8. Update `Installments::OverviewComponent` and `PaymentScheduleComponent`**

These currently call `account.installment`. Change to `account.accountable` (since Installment IS the accountable now).

**4.9. Update `AccountableSparklinesController`**

Remove the `installment_mode?` workaround.

---

### 5. i18n & Tests

**5.1. Update locale files**

File: `config/locales/en.yml`

Add keys for `installments.new.title`, `installments.form.*`, `installments.tabs.overview.*`, `accounts.types.installment`.

**5.2. Update test fixtures**

Add installment fixtures using the new accountable pattern (Installment record + Account with `accountable_type: "Installment"`). Remove any fixtures that use the old `has_one :installment` pattern.

**5.3. Update existing tests**

Any test referencing `account.installment` should be updated to `account.accountable` for Installment-type accounts. Tests for `LoansController` that test installment mode should be moved to test `InstallmentsController`.

---

## Acceptance Criteria

### Functional Requirements

- [ ] Users can create a new Installment account from the "Add Account" flow
- [ ] The installment form shows only relevant fields (no interest rate, APR, rate type)
- [ ] Payment schedule is generated correctly on creation (historical transactions + recurring payment)
- [ ] Editing an installment regenerates the schedule when schedule-affecting fields change
- [ ] Installment accounts appear in the Liabilities section of balance sheet/net worth
- [ ] Payments to installment accounts are classified as `"loan_payment"` in budgets
- [ ] The installment overview tab shows progress, next payment, and payment schedule
- [ ] Existing installment-mode Loan accounts are migrated to the new type
- [ ] Loan creation flow no longer shows installment mode
- [ ] Account deletion destroys the Installment accountable and its recurring transactions

### Non-Functional Requirements

- [ ] No N+1 queries introduced in account listing pages
- [ ] Data migration is reversible (with documented limitations)
- [ ] All existing tests pass after refactor
- [ ] New model/controller have adequate test coverage

### Quality Gates

- [ ] `bin/rails test` passes
- [ ] `bin/rubocop -f github -a` passes
- [ ] `bundle exec erb_lint ./app/**/*.erb -a` passes
- [ ] `bin/brakeman --no-pager` passes
- [ ] Data migration tested against development seed data

---

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Classification column gap during ALTER | Low | Single DDL statement (DROP + ADD in one ALTER) avoids window |
| Orphaned Loan records after migration | Low | Migration explicitly deletes orphaned records |
| Duplicate installments per account | Low | Safety assertion raises before migrating |
| RecurringTransaction orphaning | Low | `dependent: :destroy` on Installment cleans them up |
| Balance calculations wrong for migrated accounts | High | `balance_type` and `BaseCalculator` updates + thorough testing |
| API consumers break on new type | Medium | Document in API changelog |

---

## Open Questions (Deferred to Follow-up)

1. **Installment subtypes** (phone_plan, furniture, bnpl) — add when user demand is clear
2. **Interest-bearing installments** — keep as Loan for now
3. **Loan-to-Installment conversion UI** — not in v1; users delete and recreate
4. **Demo data generator** — follow-up task
5. **Provider sync mapping** — no provider maps to Installment

---

## References

- Brainstorm: `docs/brainstorms/2026-01-24-installment-accountable-type-brainstorm.md`
- Accountable concern: `app/models/concerns/accountable.rb:4`
- AccountableResource concern: `app/controllers/concerns/accountable_resource.rb`
- Current Installment model: `app/models/installment.rb`
- Current LoansController: `app/controllers/loans_controller.rb:8-130`
- Classification column: `db/schema.rb:42`
- Balance type: `app/models/account.rb:360-370`
- BaseCalculator: `app/models/balance/base_calculator.rb:73,106`
- Transfer creator: `app/models/transfer/creator.rb:77`
- Account page tabs: `app/components/UI/account_page.rb:39-48`
- Migration pattern: `db/migrate/20240619125949_rename_accountable_tables.rb`
