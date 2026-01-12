# Installment Feature - Final Implementation Specification

## Summary

This document contains all the design decisions made during the detailed interview and implementation process for the Installment feature.

## Core Decisions (24 Key Decisions)

### Historical Data & Payments
1. **Historical Transactions**: Create historical transactions for past payments when user enters an installment mid-way through
2. **Interest Breakdown**: Ignore interest breakdown - track total payment only (no principal/interest split)
3. **Balance Override**: Allow manual override of calculated balance in details page (not in form)
4. **Payment Amounts**: Support only uniform payments (no variable first/last payments)

### Payment Management
5. **Recurring Payment Edits**: Editable - users can modify like other recurring transactions
6. **Source Account**: Optional - can be added later, not required at creation time
7. **Payment Deletion**: Allow deletion of recurring payments (just skips that payment)

### Data Model
8. **Data Storage**: Create separate Installment model (not inline Account fields or JSON)
9. **Tab Data Sync**: Tabs sync data (switching between General and Installment shows same underlying data)

### Completion & Lifecycle
10. **Account on Completion**: Keep account open when complete, stop recurring payment only
11. **Payment Periods**: Add bi-weekly option (weekly, bi-weekly, monthly, quarterly, yearly)
12. **Balance Calculation**: Use scheduled dates only for balance calculation (not actual transaction dates)
13. **Early Payoff**: Manual transaction + manual installment adjustment

### Account Management
14. **Conversion Support**: No conversion from General to Installment - create new account instead
15. **Payment Date Fields**: Store both first payment date AND most recent payment date as anchors

### Currency & Sync
16. **Multi-Currency**: Lock to loan account currency (no cross-currency payments)
17. **Bank Sync**: Show both calculated and bank balance (display discrepancies)

### UI/UX
18. **Tab Implementation**: Client-side toggle (Stimulus controller)
19. **Form Guidance**: Help text below each field
20. **Zero Term Handling**: Current Term 0 means no payments yet, start from 1

### Completion Logic
21. **Completion Detection**: Check actual payment count vs expected for completion
22. **Calculation Timing**: Synchronous calculation during save (not async background job)

### Rollout & Testing
23. **Feature Flag**: Direct release (no feature flag)
24. **Testing Strategy**: Comprehensive (unit + integration + system + edge cases)

## Implementation Details

### Database Schema

**Installments Table:**
```ruby
create_table :installments, id: :uuid do |t|
  t.references :account, null: false, foreign_key: true, type: :uuid, index: true
  t.decimal :installment_cost, precision: 19, scale: 4, null: false
  t.integer :total_term, null: false
  t.integer :current_term, null: false, default: 0
  t.string :payment_period, null: false  # weekly, bi_weekly, monthly, quarterly, yearly
  t.date :first_payment_date, null: false
  t.date :most_recent_payment_date, null: false
  t.timestamps
end

# Check constraints
add_check_constraint :installments, "current_term <= total_term"
add_check_constraint :installments, "current_term >= 0"
add_check_constraint :installments, "total_term > 0"
add_check_constraint :installments, "installment_cost > 0"
```

**RecurringTransactions Update:**
```ruby
add_reference :recurring_transactions, :installment, foreign_key: true, type: :uuid, index: true
```

### Models

**Installment Model** (`app/models/installment.rb`):
- Belongs to account
- Enum for payment_period
- Delegates currency to account
- Methods:
  - `calculate_original_balance` - Returns installment_cost × total_term
  - `calculate_current_balance` - Returns remaining balance based on schedule
  - `generate_payment_schedule` - Returns array of all payment dates and amounts
  - `payments_scheduled_to_date` - Count of payments from first_payment_date to today
  - `completed?` - Returns true when payments_completed >= total_term
  - `payments_completed` - Count of actual transactions linked to installment
  - `next_payment_date` - Date of next scheduled payment
  - `payments_remaining` - total_term - payments_completed

**Account Model Updates:**
- `has_one :installment, dependent: :destroy`
- `calculated_balance` - Returns installment balance if has_installment, else normal balance
- `bank_balance` - Returns synced balance from provider

**RecurringTransaction Model Updates:**
- `belongs_to :installment, optional: true`
- `installment_managed?` - Returns true if installment_id present

### Services

**Installment::Creator** (`app/models/installment/creator.rb`):
- Initializes with installment and optional source_account_id
- `call` method runs in transaction:
  1. Generates historical transactions (if current_term > 0)
  2. Creates recurring payment (if source_account_id provided)
  3. Updates account balances

### UI Form Fields (Installment Tab)

1. **Account Name** - Text input
2. **Installment Cost** - Money input with help text: "Amount you pay each payment period"
3. **Total Term** + **Payment Period** - Same row
   - Term: Integer, help text: "Total number of payments in the plan"
   - Period: Select (Weekly, Bi-weekly, Monthly, Quarterly, Yearly)
4. **Current Term** + **Most Recent Payment Date** - Same row
   - Current Term: Integer, help text: "Which payment you're currently on (0 if not started)"
   - Payment Date: Date, help text: "Date of your most recent payment"
5. **First Payment Date** - Date input, help text: "When the installment plan started"
6. **Current Balance** - Money input, read-only, calculated, help text: "Calculated from your payment schedule"
7. **Original Loan Balance** - Money input, read-only, calculated, help text: "Total amount to be paid over life of plan"
8. **Interest Rate** + **Rate Type** - Same row (optional, not used in calculations)
9. **Source Account** - Select dropdown, optional, help text: "Which account will make these payments (optional)"
10. **Create Account** - Submit button

### Loan Details Page Additions

For accounts with installments:

1. **Overview Card**:
   - Progress indicator: "Payment X of Y" with progress bar
   - Next payment date and amount
   - Total Paid vs Remaining breakdown
   - Edit Installment Details button

2. **Payment Schedule Timeline**:
   - Visual timeline showing past/current/future payments
   - Each payment shows date and amount
   - Click payment to see associated transaction

3. **Balance Display**:
   - Calculated Balance (from schedule)
   - Bank Balance (from sync)
   - Difference indicator if they don't match

### Validation Rules

1. Current Term must be ≤ Total Term
2. Current Term must be ≥ 0
3. Total Term must be > 0
4. Installment Cost must be > 0
5. All date fields required
6. Payment period must be valid enum value
7. Warn if payment > $10,000 AND total_term < 3 (unusual installment warning)

### Transaction Linking

Historical and future transactions link to installment via:
```ruby
extra: {
  "installment_id" => installment.id.to_s,
  "installment_payment_number" => payment_number
}
```

### Completion Logic

When recurring payment executes:
1. Create transaction as normal
2. Check `installment.completed?` (counts actual transactions via extra data)
3. If count >= total_term, mark recurring transaction as inactive
4. Account remains open

## Files Created/Modified

### New Files
- `db/migrate/XXXXXX_drop_old_installments_table.rb`
- `db/migrate/XXXXXX_create_installments.rb`
- `db/migrate/XXXXXX_add_installment_to_recurring_transactions.rb`
- `app/models/installment.rb`
- `app/models/installment/creator.rb`
- `test/models/installment_test.rb`
- `test/models/installment/creator_test.rb`

### Modified Files
- `app/models/account.rb` - Added installment relationship and balance methods
- `app/models/recurring_transaction.rb` - Added installment reference and methods

## Testing Coverage

### Unit Tests (installment_test.rb)
- ✅ Validations (presence, numericality, constraints)
- ✅ Calculate original balance
- ✅ Calculate current balance (various current_term values)
- ✅ Payment schedule generation (all periods)
- ✅ Completion detection
- ✅ Payment counting
- ✅ Edge cases (current_term = 0, current_term = total_term)

### Integration Tests (creator_test.rb)
- ✅ Historical transaction generation
- ✅ Recurring transaction creation
- ✅ Account balance updates
- ✅ Transaction rollback on error
- ✅ Installment linking via extra data

## Next Steps (Not Yet Implemented)

The following tasks remain to complete the feature:

1. **Controller Updates** - Update AccountsController to handle installment mode
2. **Stimulus Controller** - Create loan form tabs controller
3. **Form View** - Update loan form with Installment tab
4. **ViewComponents** - Create Overview and PaymentSchedule components
5. **Details Page** - Update loan account show page with installment info
6. **i18n Strings** - Add all localized strings
7. **System Tests** - End-to-end flow tests
8. **Linting & Security** - Run rubocop and brakeman

## Known Issues & Limitations

1. **Validation Logic**: The "unusual cost" validation checks if payment > $10,000 AND term < 3. This is a simplified heuristic.
2. **Recurring Transaction Unique Constraint**: May cause issues if creating multiple installments with same parameters
3. **Balance Calculation**: Relies on scheduled dates, doesn't account for skipped/early payments automatically

## Future Enhancements (Out of Scope)

- Variable first/last payment support
- Conversion between General and Installment modes
- Interest/principal breakdown calculations
- Automatic balance reconciliation
- Payment reminder notifications
- Refinancing support
- Bulk installment import
- Amortization schedule export

## Migration Notes

- Old installments table was dropped (had different schema with family_id)
- installment_id removed from transactions table (old implementation)
- New implementation uses transaction.extra JSON field for linking
- Check constraints ensure data integrity at database level

---

**Status**: Models and business logic complete. UI implementation pending.
**Last Updated**: 2026-01-12
**Implementation By**: Claude Code (Sonnet 4.5)
