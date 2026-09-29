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

  # A lone materialized paycheck landing today yields an empty plan; the tool
  # answers with its guidance instead of raising on the missing periods.
  test "a lone paycheck landing today returns guidance rather than raising" do
    series = @family.recurring_transactions.create!(
      name: "Paycheck", account: accounts(:depository), amount: -1840,
      currency: "USD", bill_type: "income", manual: true,
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current, status: "active"
    )
    series.recurring_occurrences.where("due_on > ?", Date.current).delete_all

    result = call_tool

    assert_equal "No declared income schedule", result[:error]
    assert result[:hint].present?
  end

  # Same class of bug as the get_bills one: the planner counts confirmed series
  # only, which is correct, but every figure it returns is spending headroom, so
  # dropping unconfirmed detections without a word makes the plan look safer
  # than it is.
  test "a plan that ignores unconfirmed detections says so" do
    declare_income
    @family.recurring_transactions.create!(
      name: "Detected subscription", account: accounts(:depository), amount: 40,
      currency: "USD", expected_day_of_month: Date.current.day, status: "suggested",
      bill_type: "subscription", manual: false, dedup_scope: "detected-40",
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current
    )

    result = call_tool

    assert result[:unconfirmed_excluded].present?,
      "the plan must disclose obligations it left out"
    assert_equal 1, result[:unconfirmed_excluded][:count]
    assert_match(/upper bound/, result[:unconfirmed_excluded][:note])
  end

  test "no exclusion notice when everything is confirmed" do
    declare_income

    result = call_tool

    assert result[:periods].present?
    assert_nil result[:unconfirmed_excluded]
  end


  # The assistant answered "Shortfall: $150.00, Safe after bills: -$150.00" for
  # a window funded entirely from money already in the bank. A bridge earns
  # nothing, so income minus obligations is a deficit by construction, and the
  # deficit sat right beside short: false.
  test "a bridge window reports headroom against cash, not against its zero income" do
    set_cash(900)
    declare_future_income
    declare_bridge_bill(amount: 150)

    bridge = call_tool[:periods].find { |period| period[:bridge] }

    assert_equal false, bridge[:short]
    assert_equal "$750.00", bridge[:safe_after_bills],
      "cash minus what is due out of it, never income minus obligations"
    assert_equal "$900.00", bridge[:cash_on_hand]
  end

  test "a bridge the cash cannot cover still reports short" do
    set_cash(100)
    declare_future_income
    declare_bridge_bill(amount: 150)

    bridge = call_tool[:periods].find { |period| period[:bridge] }

    assert_equal true, bridge[:short]
    assert_equal "-$50.00", bridge[:safe_after_bills]
  end

  test "an unreadable balance omits the figure rather than inventing one" do
    @family.accounts.update_all(status: "disabled")
    declare_future_income
    declare_bridge_bill(amount: 150)

    bridge = call_tool[:periods].find { |period| period[:bridge] }

    assert_equal false, bridge[:short]
    assert_not bridge.key?(:safe_after_bills),
      "no balance means no honest headroom figure, so the key goes rather than guessing"
    assert_not bridge.key?(:cash_on_hand)
  end

  private

    # The shared declare_income pays today, so there is no gap before the next
    # payday and no bridge window at all. These tests need one.
    def declare_future_income
      payday = Date.current + 5
      series = @family.recurring_transactions.create!(
        name: "Payday", account: accounts(:depository), amount: -2000,
        currency: "USD", expected_day_of_month: payday.day, status: "active",
        bill_type: "income", manual: true, dedup_scope: "future-payday--2000",
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: payday
      )
      series.recurring_occurrences.destroy_all
      series.recurring_occurrences.create!(
        family: @family, original_due_on: payday, due_on: payday,
        currency: "USD", expected_amount: 2000, status: "scheduled"
      )
      series
    end

    def set_cash(amount)
      accounts = @family.accounts.where(accountable_type: "Depository")
      accounts.update_all(balance: amount / accounts.count.to_d)
    end

    def declare_bridge_bill(amount:)
      series = @family.recurring_transactions.create!(
        name: "Haircut", account: accounts(:depository), amount: amount,
        currency: "USD", status: "active", bill_type: "bill", manual: true,
        dedup_scope: "haircut-#{amount}", expected_day_of_month: (Date.current + 1).day,
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current + 1
      )
      series.recurring_occurrences.destroy_all
      series.recurring_occurrences.create!(
        family: @family, original_due_on: Date.current + 1, due_on: Date.current + 1,
        currency: "USD", expected_amount: amount, status: "scheduled"
      )
      series
    end

    def call_tool(params = {})
      Assistant::Function::GetPaycheckPlan.new(@user).call(params)
    end

    def declare_income
      @family.recurring_transactions.create!(
        name: "Payday", account: accounts(:depository), amount: -2000,
        currency: "USD", expected_day_of_month: Date.current.day, status: "active",
        bill_type: "income", manual: true, dedup_scope: "payday--2000",
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current
      )
    end
end
