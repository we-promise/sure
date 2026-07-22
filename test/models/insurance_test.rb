require "test_helper"

class InsuranceTest < ActiveSupport::TestCase
  test "validates policy fields" do
    insurance = Insurance.new(
      subtype: "invalid",
      premium_frequency: "weekly",
      coverage_amount: -1,
      premium_amount: -1,
      effective_date: Date.new(2026, 2, 1),
      expiration_date: Date.new(2026, 1, 1)
    )

    assert_not insurance.valid?
    assert_includes insurance.errors[:subtype], "is not included in the list"
    assert_includes insurance.errors[:premium_frequency], "is not included in the list"
    assert_predicate insurance.errors[:coverage_amount], :present?
    assert_predicate insurance.errors[:premium_amount], :present?
    assert_predicate insurance.errors[:expiration_date], :present?
  end

  test "derives policy status from policy dates" do
    insurance = Insurance.new
    today = Date.new(2026, 7, 22)

    assert_equal :active, insurance.policy_status(on: today)

    insurance.effective_date = today + 1.day
    assert_equal :upcoming, insurance.policy_status(on: today)

    insurance.effective_date = today - 1.year
    insurance.expiration_date = today - 1.day
    assert_equal :expired, insurance.policy_status(on: today)

    insurance.expiration_date = today + 1.year
    insurance.renewal_date = today + 15.days
    assert_equal :renewal_due, insurance.policy_status(on: today)

    insurance.renewal_date = nil
    insurance.expiration_date = today + 15.days
    assert_equal :expiring_soon, insurance.policy_status(on: today)
  end

  test "returns monetary policy values in the account currency" do
    account = accounts(:insurance)

    assert_equal Money.new(500000, "USD"), account.insurance.coverage_amount_money
    assert_equal Money.new(150, "USD"), account.insurance.premium_amount_money
  end
end
