require "test_helper"

# Tests that Transaction::Search correctly classifies refunds in type filters
# and totals SQL.
#
# Key contracts:
#   - "expense" filter includes refunds (they offset spend, not income).
#   - "income"  filter excludes refunds.
#   - expense_total is reduced (not increased) by refund amounts.
#   - income_total is unaffected by refund amounts.
class Transaction::SearchRefundTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create!(
      name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    )
  end

  # ---------------------------------------------------------------------------
  # Type filter
  # ---------------------------------------------------------------------------

  test "expense filter includes refund transactions" do
    refund_entry   = create_transaction(account: @checking, amount: -50,  refund: true)
    expense_entry  = create_transaction(account: @checking, amount: 100,  kind: "standard")
    income_entry   = create_transaction(account: @checking, amount: -80,  kind: "standard")

    result_ids = Transaction::Search.new(@family, filters: { types: [ "expense" ] })
                                    .transactions_scope.pluck(:id)

    assert_includes     result_ids, refund_entry.entryable.id,  "refund must appear under expense filter"
    assert_includes     result_ids, expense_entry.entryable.id
    assert_not_includes result_ids, income_entry.entryable.id
  end

  test "income filter excludes refund transactions" do
    refund_entry  = create_transaction(account: @checking, amount: -50, refund: true)
    income_entry  = create_transaction(account: @checking, amount: -80, kind: "standard")

    result_ids = Transaction::Search.new(@family, filters: { types: [ "income" ] })
                                    .transactions_scope.pluck(:id)

    assert_not_includes result_ids, refund_entry.entryable.id, "refund must NOT appear under income filter"
    assert_includes     result_ids, income_entry.entryable.id
  end

  test "expense+transfer filter includes refund" do
    refund_entry   = create_transaction(account: @checking, amount: -50,  refund: true)
    transfer_entry = create_transaction(account: @checking, amount: 200,  kind: "funds_movement")

    result_ids = Transaction::Search.new(@family, filters: { types: [ "expense", "transfer" ] })
                                    .transactions_scope.pluck(:id)

    assert_includes result_ids, refund_entry.entryable.id
    assert_includes result_ids, transfer_entry.entryable.id
  end

  test "income+transfer filter excludes refund" do
    refund_entry   = create_transaction(account: @checking, amount: -50, refund: true)
    income_entry   = create_transaction(account: @checking, amount: -80, kind: "standard")
    transfer_entry = create_transaction(account: @checking, amount: 200, kind: "funds_movement")

    result_ids = Transaction::Search.new(@family, filters: { types: [ "income", "transfer" ] })
                                    .transactions_scope.pluck(:id)

    assert_not_includes result_ids, refund_entry.entryable.id
    assert_includes     result_ids, income_entry.entryable.id
    assert_includes     result_ids, transfer_entry.entryable.id
  end

  # ---------------------------------------------------------------------------
  # Totals SQL
  # ---------------------------------------------------------------------------

  test "totals: refund reduces expense_total and does not add to income_total" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    create_transaction(account: @checking, amount: 200,  kind: "standard")  # $200 expense
    create_transaction(account: @checking, amount: -50,  refund: true)      # $50 refund (offsets expense)
    create_transaction(account: @checking, amount: -100, kind: "standard")  # $100 income

    totals = Transaction::Search.new(@family).totals

    # expense_total: 200 (expense) - 50 (refund) = 150
    assert_equal Money.new(150, @family.currency), totals.expense_money,
      "refund should reduce expense_total"

    # income_total: 100 only — refund must not contribute
    assert_equal Money.new(100, @family.currency), totals.income_money,
      "refund must not appear in income_total"
  end

  test "totals: refund with no matching expense flips to income" do
    Entry.joins(:account).where(accounts: { family_id: @family.id }).destroy_all

    # Only a refund, no expense
    create_transaction(account: @checking, amount: -80, refund: true)

    totals = Transaction::Search.new(@family).totals

    assert_equal Money.new(0,  @family.currency), totals.expense_money,
      "standalone refund should not appear as expense"
    assert_equal Money.new(80, @family.currency), totals.income_money,
      "standalone refund should appear as income"
  end
end
