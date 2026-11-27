require "test_helper"

# Value-presence rules for each edge mode, plus the guardrails that keep a
# crafted id from pinning an edge to a bill or another family's series.
class IncomeAccountAllocationTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @account = accounts(:depository)
    @income = create_income_series(family: @family, account: @account)
    @other_family = families(:empty)
  end

  def create_income_series(family:, account:, amount: 100)
    family.recurring_transactions.create!(
      name: "Payroll",
      account: account,
      amount: amount,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      status: "active",
      bill_type: "income",
      manual: true
    )
  end

  def build(mode:, value:)
    IncomeAccountAllocation.new(
      family: @family,
      income_series: @income,
      account: @account,
      mode: mode,
      value: value
    )
  end

  test "specific requires a positive per-paycheck amount" do
    assert_not build(mode: "specific", value: nil).valid?
    assert_not build(mode: "specific", value: 0).valid?
    assert_not build(mode: "specific", value: -5).valid?
    assert build(mode: "specific", value: 100).valid?
    assert build(mode: "specific", value: 0.01).valid?
  end

  test "percent requires a fraction in (0, 1]" do
    assert_not build(mode: "percent", value: nil).valid?
    assert_not build(mode: "percent", value: 0).valid?
    assert_not build(mode: "percent", value: 1.5).valid?
    assert build(mode: "percent", value: 0.5).valid?
    assert build(mode: "percent", value: 1).valid?
  end

  test "required and leftover carry no stored value" do
    assert_not build(mode: "required", value: 5).valid?
    assert build(mode: "required", value: nil).valid?
    assert_not build(mode: "leftover", value: 0.25).valid?
    assert build(mode: "leftover", value: nil).valid?
  end

  test "the income series must be a declared income" do
    bill = recurring_transactions(:netflix_subscription) # a subscription
    allocation = IncomeAccountAllocation.new(
      family: @family,
      income_series: bill,
      account: @account,
      mode: "leftover"
    )
    assert_not allocation.valid?
    assert allocation.errors[:income_series].any?
  end

  test "the series and account must belong to the same family" do
    allocation = build(mode: "leftover", value: nil)
    other_user = @other_family.users.first
    other_account = @other_family.accounts.create!(
      name: "Other", owner: other_user, currency: "USD", balance: 0, accountable: Depository.new
    )
    allocation.account = other_account
    assert_not allocation.valid?
    assert allocation.errors[:account].any?
  end
end
