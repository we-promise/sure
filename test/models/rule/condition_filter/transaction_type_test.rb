require "test_helper"

class Rule::ConditionFilter::TransactionTypeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @rule = rules(:one)
    @filter = Rule::ConditionFilter::TransactionType.new(@rule)
    @family = families(:dylan_family)
  end

  # Regression: this filter (and Transaction::Search, which it deliberately
  # mirrors) decides income/expense/transfer purely from
  # Transaction::TRANSFER_KINDS. While auto-match leaves both legs as kind
  # "standard", a detected transfer's outflow reads as an expense and its
  # inflow as income, so any "if transaction type is expense" rule now fires
  # on transfer legs it used to skip -- re-categorizing and re-naming them.
  test "pending auto-matched legs are not treated as income or expense" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    @family.auto_match_transfers!
    assert outflow_entry.transaction.reload.transfer&.pending?, "auto-match did not pair the two 500 transactions"

    scope = @filter.prepare(@family.transactions)

    assert_not_includes @filter.apply(scope, "=", "expense").pluck(:id), outflow_entry.transaction.id
    assert_not_includes @filter.apply(scope, "=", "income").pluck(:id), inflow_entry.transaction.id
  end

  test "pending auto-matched legs are treated as transfers" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    @family.auto_match_transfers!

    scope = @filter.prepare(@family.transactions)
    transfer_ids = @filter.apply(scope, "=", "transfer").pluck(:id)

    assert_includes transfer_ids, outflow_entry.transaction.id
    assert_includes transfer_ids, inflow_entry.transaction.id
  end
end
