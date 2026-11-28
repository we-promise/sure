require "test_helper"

class RecurringTransaction::SearchTest < ActiveSupport::TestCase
  setup do
    @scope = families(:dylan_family).recurring_transactions
  end

  test "returns the whole scope when no filter is set" do
    assert_equal @scope.ids.sort, RecurringTransaction::Search.new(@scope).recurring_transactions_scope.ids.sort
  end

  test "status keeps series in that status" do
    results = RecurringTransaction::Search.new(@scope, filters: { status: "inactive" }).recurring_transactions_scope

    assert_equal [ recurring_transactions(:inactive_subscription) ], results.to_a
  end

  test "account_id keeps series on that account" do
    results = RecurringTransaction::Search.new(@scope, filters: { account_id: accounts(:depository).id }).recurring_transactions_scope

    assert_equal [ recurring_transactions(:netflix_subscription) ], results.to_a
  end

  test "never widens the scope it is given" do
    narrowed = @scope.where.not(id: recurring_transactions(:netflix_subscription).id)

    assert_empty RecurringTransaction::Search.new(narrowed, filters: { account_id: accounts(:depository).id }).recurring_transactions_scope
  end
end
