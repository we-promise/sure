require "test_helper"

class Rule::ConditionFilter::TransactionTypeTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @filter = Rule::ConditionFilter::TransactionType.new(rules(:one))
    @account = accounts(:depository)
  end

  test "treats refunds as expenses and not income, matching transaction search" do
    refund = create_transaction(account: @account, amount: -50, refund: true)
    income = create_transaction(account: @account, amount: -75)

    scope = @filter.prepare(@family.transactions)
    expense_ids = @filter.apply(scope, "=", "expense").pluck(:id)
    income_ids = @filter.apply(scope, "=", "income").pluck(:id)

    assert_includes expense_ids, refund.entryable.id
    assert_not_includes income_ids, refund.entryable.id
    assert_includes income_ids, income.entryable.id
  end
end
