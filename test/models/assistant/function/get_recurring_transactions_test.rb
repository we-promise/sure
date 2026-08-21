require "test_helper"

class Assistant::Function::GetRecurringTransactionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetRecurringTransactions.new(@user)
  end

  test "has correct name" do
    assert_equal "get_recurring_transactions", @fn.name
  end

  test "has a description" do
    assert_not_empty @fn.description
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "defaults to active recurring transactions only" do
    result = @fn.call

    names = result[:recurring_transactions].map { |rt| rt[:name] }

    assert_includes names, "Netflix"
    assert_not_includes names, "Amazon"
    assert result[:recurring_transactions].all? { |rt| rt[:status] == "active" }
  end

  test "status all returns inactive items too" do
    result = @fn.call("status" => "all")

    assert_includes result[:recurring_transactions].map { |rt| rt[:name] }, "Amazon"
  end

  test "upcoming_within_days windows on next expected date" do
    result = @fn.call("upcoming_within_days" => 2)

    assert_empty result[:recurring_transactions]

    wide = @fn.call("upcoming_within_days" => 30)

    assert_includes wide[:recurring_transactions].map { |rt| rt[:name] }, "Netflix"
  end

  test "totals sum active items per currency and exclude transfers" do
    checking = @family.accounts.visible.first
    savings = @family.accounts.visible.second

    @family.recurring_transactions.create!(
      name: "Vault transfer",
      account: checking,
      destination_account: savings,
      amount: 500,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 1.month.from_now.to_date,
      status: "active",
      occurrence_count: 4
    )

    result = @fn.call("status" => "all")
    transfer_row = result[:recurring_transactions].find { |rt| rt[:name] == "Vault transfer" }

    assert transfer_row[:is_transfer]
    assert_equal "$15.99", result[:totals_by_currency]["USD"]
    assert_equal false, result[:truncated]
    assert_equal result[:recurring_transactions].size, result[:total_results]
  end

  test "does not return another family's recurring transactions" do
    result = Assistant::Function::GetRecurringTransactions.new(users(:empty)).call("status" => "all")

    assert_empty result[:recurring_transactions]
  end
end
