require "test_helper"

class Account::RunningBalanceCalculatorTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  # Opening balance: 1000
  # 09:00 transaction: -100 -> 900
  # 10:00 transaction: +250 -> 1150
  # 11:00 transaction: -50  -> 1100
  #
  # Note: Entry#amount is stored in "ledger" sign (positive = outflow/expense,
  # negative = inflow), the inverse of what's displayed to the user
  # (`format_money(-entry.amount_money)` in the compact row partials). So a
  # displayed "-100" is `amount: 100` below.
  test "computes exact per-transaction running balance in chronological order" do
    date = 2.days.ago.to_date

    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: date - 1.day, balance: 1000 }
      ]
    )

    Balance::Materializer.new(account, strategy: :forward).materialize_balances

    entry_1 = account.entries.create!(name: "Coffee", date: date, amount: 100, currency: "USD", entryable: Transaction.new, created_at: Time.utc(date.year, date.month, date.day, 9, 0, 0))
    entry_2 = account.entries.create!(name: "Refund", date: date, amount: -250, currency: "USD", entryable: Transaction.new, created_at: Time.utc(date.year, date.month, date.day, 10, 0, 0))
    entry_3 = account.entries.create!(name: "Snack", date: date, amount: 50, currency: "USD", entryable: Transaction.new, created_at: Time.utc(date.year, date.month, date.day, 11, 0, 0))

    running_balances = Account::RunningBalanceCalculator.new([ entry_1, entry_2, entry_3 ]).running_balances

    assert_equal 900, running_balances[entry_1.id].amount
    assert_equal 1150, running_balances[entry_2.id].amount
    assert_equal 1100, running_balances[entry_3.id].amount
  end

  test "liability account flips the sign of the flow" do
    date = 2.days.ago.to_date

    account = create_account_with_ledger(
      account: { type: CreditCard, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: date - 1.day, balance: 1000 }
      ]
    )

    Balance::Materializer.new(account, strategy: :forward).materialize_balances

    # A charge (positive amount) increases debt on a liability account
    charge = account.entries.create!(name: "Charge", date: date, amount: 100, currency: "USD", entryable: Transaction.new)
    # A payment (negative amount) decreases debt on a liability account
    payment = account.entries.create!(name: "Payment", date: date, amount: -300, currency: "USD", entryable: Transaction.new, created_at: charge.created_at + 1.hour)

    running_balances = Account::RunningBalanceCalculator.new([ charge, payment ]).running_balances

    assert_equal 1100, running_balances[charge.id].amount
    assert_equal 800, running_balances[payment.id].amount
  end

  test "valuation entry resets the running balance instead of being summed as a flow" do
    date = 2.days.ago.to_date

    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: date - 1.day, balance: 1000 }
      ]
    )

    Balance::Materializer.new(account, strategy: :forward).materialize_balances

    # Entry.chronological always orders a day's Valuation after that day's other
    # entries (regardless of creation time), since a same-day valuation is meant
    # to represent the post-everything-else balance for that day.
    entry_1 = account.entries.create!(name: "Coffee", date: date, amount: 100, currency: "USD", entryable: Transaction.new, created_at: Time.utc(date.year, date.month, date.day, 9, 0, 0))
    reconciliation = account.entries.create!(name: "Reconciliation", date: date, amount: 2000, currency: "USD", entryable: Valuation.new(kind: "reconciliation"), created_at: Time.utc(date.year, date.month, date.day, 10, 0, 0))
    entry_2 = account.entries.create!(name: "Snack", date: date + 1.day, amount: 50, currency: "USD", entryable: Transaction.new)

    running_balances = Account::RunningBalanceCalculator.new([ entry_1, reconciliation, entry_2 ]).running_balances

    assert_equal 900, running_balances[entry_1.id].amount
    # The valuation resets the total to its absolute amount, ignoring the running total up to that point
    assert_equal 2000, running_balances[reconciliation.id].amount
    # A later entry continues accumulating from the reset value
    assert_equal 1950, running_balances[entry_2.id].amount
  end

  test "pending transactions are excluded and fall back to the last known running total" do
    date = 2.days.ago.to_date

    account = create_account_with_ledger(
      account: { type: Depository, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: date - 1.day, balance: 1000 }
      ]
    )

    Balance::Materializer.new(account, strategy: :forward).materialize_balances

    entry_1 = account.entries.create!(name: "Coffee", date: date, amount: 100, currency: "USD", entryable: Transaction.new, created_at: Time.utc(date.year, date.month, date.day, 9, 0, 0))
    pending_transaction = Transaction.new(extra: { "plaid" => { "pending" => true } })
    pending_entry = account.entries.create!(name: "Pending charge", date: date, amount: 25, currency: "USD", entryable: pending_transaction, created_at: Time.utc(date.year, date.month, date.day, 10, 0, 0))

    running_balances = Account::RunningBalanceCalculator.new([ entry_1, pending_entry ]).running_balances

    assert_equal 900, running_balances[entry_1.id].amount
    assert_equal 900, running_balances[pending_entry.id].amount
  end

  test "investment accounts fall back to the per-day balance" do
    date = 2.days.ago.to_date

    account = create_account_with_ledger(
      account: { type: Investment, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: date - 1.day, balance: 1000 }
      ]
    )

    Holding::Materializer.any_instance.stubs(:materialize_holdings).returns([])
    Balance::Materializer.new(account, strategy: :forward).materialize_balances

    entry_1 = account.entries.create!(name: "Deposit", date: date, amount: -100, currency: "USD", entryable: Transaction.new)
    entry_2 = account.entries.create!(name: "Withdrawal", date: date, amount: 50, currency: "USD", entryable: Transaction.new)

    running_balances = Account::RunningBalanceCalculator.new([ entry_1, entry_2 ]).running_balances

    # Both entries share the same calendar day, so the (intentional) per-day fallback
    # gives them the same end-of-day figure, unlike the cash-only path above.
    assert_equal running_balances[entry_1.id].amount, running_balances[entry_2.id].amount
  end
end
