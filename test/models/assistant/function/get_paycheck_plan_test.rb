require "test_helper"

class Assistant::Function::GetPaycheckPlanTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "no declared income returns an error with a hint instead of a fabricated plan" do
    # A detected inflow is income by sign but declares no payday.
    @family.recurring_transactions.create!(
      name: "Deposit From Checking", account: accounts(:depository), amount: -0.01,
      currency: "USD", bill_type: "income", manual: false,
      expected_day_of_month: Date.current.day,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current,
      status: "active"
    )

    result = call_tool

    assert_equal "No declared income schedule", result[:error]
    assert_includes result[:hint], "declared"
  end

  test "declared income produces periods with due, reserved and safe figures" do
    payday = Date.current + 3
    @family.recurring_transactions.create!(
      name: "Paycheck", account: accounts(:depository), amount: -1200,
      currency: "USD", bill_type: "income", manual: true,
      expected_day_of_month: payday.day, anchor_date: payday,
      last_occurrence_date: payday, next_expected_date: payday, status: "active"
    )
    due = payday + 4
    @family.recurring_transactions.create!(
      name: "Rent", account: accounts(:depository), amount: 500,
      currency: "USD", bill_type: "bill", manual: true,
      expected_day_of_month: due.day, anchor_date: due,
      last_occurrence_date: due, next_expected_date: due, status: "active"
    )

    result = call_tool("periods_limit" => 2)

    assert_equal @family.currency, result[:family_currency]
    assert_operator result[:periods].size, :>=, 1

    period_with_rent = result[:periods].find { |period| period[:bills_due].any? { |bill| bill[:name] == "Rent" } }
    assert period_with_rent.present?, "the rent must land in a period as due"
    assert period_with_rent[:income].present?
    assert period_with_rent[:safe_after_bills].present?
  end

  private

    def call_tool(params = {})
      Assistant::Function::GetPaycheckPlan.new(@user).call(params)
    end
end
