require "test_helper"

# The year-by-year planner's settings and records: the new columns on
# retirement_plans, its spending and income streams, and its funding accounts.
class RetirementPlan::PlannerSettingsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    RetirementPlan.where(user: @user).delete_all
    @plan = RetirementPlan.create!(user: @user)
  end

  test "an unsaved plan carries the planner defaults: end age 90, 3% inflation, traditional mode" do
    RetirementPlan.where(user: @user).delete_all
    plan = RetirementPlan.for(@user)

    assert_equal [ 90, BigDecimal("0.03"), "traditional", nil ],
                 [ plan.end_age, plan.inflation_rate, plan.mode, plan.birth_year ]
  end

  test "a plan saved with only the simple settings still saves" do
    @plan.update!(safe_withdrawal_rate_percent: "3.5", expected_annual_return_percent: "6",
                  savings_rate_percent: "", retirement_date: Date.new(2045, 6, 30))

    assert_equal BigDecimal("0.035"), @plan.reload.safe_withdrawal_rate
  end

  test "inflation is set and shown in percent, like the other rates" do
    @plan.update!(inflation_rate_percent: "2.5")

    assert_equal BigDecimal("0.025"), @plan.reload.inflation_rate
    assert_equal BigDecimal("2.5"), @plan.inflation_rate_percent
  end

  test "an end age outside 50 to 120 is refused, and the bounds are allowed" do
    [ 49, 121, nil ].each { |age| assert_not @plan.tap { |p| p.end_age = age }.valid?, "#{age.inspect} should be refused" }
    [ 50, 120 ].each { |age| assert @plan.tap { |p| p.end_age = age }.valid?, "#{age} should be allowed" }
  end

  test "a birth year outside 1900 to 2100 is refused, and a blank one is allowed" do
    [ 1899, 2101 ].each { |year| assert_not @plan.tap { |p| p.birth_year = year }.valid?, "#{year} should be refused" }
    [ nil, 1900, 1980 ].each { |year| assert @plan.tap { |p| p.birth_year = year }.valid?, "#{year.inspect} should be allowed" }
  end

  test "inflation of -100% or less, or above 100%, is refused" do
    [ -1, BigDecimal("1.01") ].each { |rate| assert_not @plan.tap { |p| p.inflation_rate = rate }.valid? }
    assert @plan.tap { |p| p.inflation_rate = 0 }.valid?
  end

  test "the mode is traditional or fire and nothing else" do
    assert_not @plan.tap { |p| p.mode = "yolo" }.valid?
    assert @plan.tap { |p| p.mode = "fire" }.valid?
  end

  test "the database refuses an end age that bypasses the model" do
    assert_raises(ActiveRecord::StatementInvalid) { @plan.update_columns(end_age: 10) }
  end

  test "a stream needs a known kind, a positive amount and an end no earlier than its start" do
    assert @plan.streams.new(kind: "expense", name: "Living costs", annual_amount: 1).valid?

    [
      { kind: "salary" },
      { annual_amount: 0 },
      { start_year: 2040, end_year: 2039 },
      { name: "" }
    ].each do |bad|
      stream = @plan.streams.new({ kind: "expense", name: "Living costs", annual_amount: 1 }.merge(bad))
      assert_not stream.valid?, "#{bad} should be refused"
    end
  end

  test "the database refuses a stream amount of zero that bypasses the model" do
    stream = @plan.streams.create!(kind: "expense", name: "Living costs", annual_amount: 1)

    assert_raises(ActiveRecord::StatementInvalid) { stream.update_columns(annual_amount: 0) }
  end

  test "deleting the plan deletes its streams and its funding links" do
    account = @family.accounts.first
    @plan.streams.create!(kind: "expense", name: "Living costs", annual_amount: 1)
    @plan.funding_links.create!(account: account)

    assert_difference [ "RetirementPlan::Stream.count", "RetirementPlan::FundingAccount.count" ], -1 do
      @plan.destroy
    end
  end

  test "deleting a loan's account keeps its stream and forgets the account" do
    loan = Account.create!(family: @family, owner: @user, accountable: Loan.new, name: "Mortgage", currency: "USD", balance: 1000)
    stream = @plan.streams.create!(kind: "expense", name: "Mortgage", annual_amount: 12_000, source: "seeded_loan", account: loan)

    loan.destroy!

    assert_nil stream.reload.account_id
  end

  test "an account is linked to a plan at most once" do
    account = @family.accounts.first
    @plan.funding_links.create!(account: account)

    assert_not @plan.funding_links.new(account: account).valid?
  end

  # --- Monte Carlo settings ------------------------------------------------

  test "an unsaved plan carries the Monte Carlo defaults: 12% volatility and a 90% target" do
    RetirementPlan.where(user: @user).delete_all
    plan = RetirementPlan.for(@user)

    assert_equal [ BigDecimal("0.12"), BigDecimal("0.9") ], [ plan.return_volatility, plan.success_target ]
  end

  test "volatility and the target are set in percent" do
    @plan.update!(return_volatility_percent: "15", success_target_percent: "85")

    assert_equal [ BigDecimal("0.15"), BigDecimal("0.85") ], [ @plan.reload.return_volatility, @plan.success_target ]
  end

  test "volatility outside 0 to 100% and a target of 0 or above 100% are refused" do
    [ BigDecimal("-0.01"), BigDecimal("1.01") ].each { |v| assert_not @plan.tap { |p| p.return_volatility = v }.valid?, "#{v}" }
    @plan.return_volatility = 0
    [ 0, BigDecimal("1.01") ].each { |t| assert_not @plan.tap { |p| p.success_target = t }.valid?, "#{t}" }
    @plan.success_target = 1
    assert @plan.valid?
  end

  test "the database refuses a target of zero that bypasses the model" do
    assert_raises(ActiveRecord::StatementInvalid) { @plan.update_columns(success_target: 0) }
  end
end
