require "test_helper"

class AccountContributionTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
  end

  test "withdrawals are stored as money out whatever sign was entered" do
    contribution = @account.account_contributions.create!(date: Date.new(2025, 1, 1), amount: 500, kind: "withdrawal")

    assert_equal(-500, contribution.amount)
    assert contribution.outflow?
    assert_equal "USD", contribution.currency
  end

  test "a negative contribution is recorded as a withdrawal" do
    contribution = @account.account_contributions.create!(date: Date.new(2025, 1, 1), amount: -200, kind: "contribution")

    assert_equal "withdrawal", contribution.kind
  end

  test "principal value defaults to the amount and can be overridden" do
    plain = @account.account_contributions.create!(date: Date.new(2025, 1, 1), amount: 1000, kind: "contribution")
    transfer = @account.account_contributions.create!(date: Date.new(2025, 2, 1), amount: 5000, principal_amount: 3000, kind: "transfer_in")

    assert_equal 1000, plain.principal_value
    assert_equal 3000, transfer.principal_value
  end

  test "rejects a zero amount" do
    contribution = @account.account_contributions.build(date: Date.current, amount: 0, kind: "contribution")

    assert_not contribution.valid?
  end
end
