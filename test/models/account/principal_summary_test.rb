require "test_helper"

class Account::PrincipalSummaryTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @account.account_contributions.create!(date: Date.new(2025, 1, 10), amount: 4000, kind: "contribution")
    @account.account_contributions.create!(date: Date.new(2025, 2, 10), amount: 1000, kind: "employer_contribution")
    @account.account_contributions.create!(date: Date.new(2025, 3, 10), amount: 500, kind: "withdrawal")
  end

  test "principal is net money in and earnings are the rest of the balance" do
    summary = Account::PrincipalSummary.new(@account)

    assert summary.available?
    assert_equal Money.new(4500, "USD"), summary.principal
    assert_equal Money.new(5500, "USD"), summary.earnings
    assert_equal BigDecimal("122.2"), summary.return_percent
    assert_equal Money.new(5000, "USD"), summary.total_in
    assert_equal Money.new(500, "USD"), summary.total_out
  end

  test "series carries the running principal for each date" do
    values = Account::PrincipalSummary.new(@account).series_values(
      [ Date.new(2025, 1, 1), Date.new(2025, 1, 10), Date.new(2025, 2, 28), Date.new(2025, 4, 1) ]
    )

    assert_equal [ 0, 4000, 5000, 4500 ], values.map { |v| v[:value] }
  end

  test "not available without contributions" do
    assert_not Account::PrincipalSummary.new(accounts(:depository)).available?
  end
end
