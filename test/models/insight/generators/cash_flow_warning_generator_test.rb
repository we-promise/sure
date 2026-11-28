require "test_helper"

class Insight::Generators::CashFlowWarningGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @series = @family.recurring_transactions.create!(
      name: "Horizon Power", account: accounts(:depository), amount: 100, currency: "USD",
      expected_day_of_month: 15, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true
    )
    # The series generates its own horizon on create; clear it so the test
    # owns exactly three known occurrences.
    @series.recurring_occurrences.delete_all
    @occurrences = 3.times.map do |i|
      @series.recurring_occurrences.create!(
        family: @family,
        original_due_on: Date.current + i + 1,
        due_on: Date.current + i + 1,
        currency: "USD"
      )
    end
    RecurringAllocation.create!(
      recurring_occurrence: @occurrences.first, state: :confirmed, source: :user_confirmed,
      allocated_amount: 40, currency: "USD", paid_on: Date.current
    )
  end

  test "remaining amounts come from one grouped sum, not one query per occurrence" do
    generator = Insight::Generators::CashFlowWarningGenerator.new(@family)

    sum_queries = 0
    counter = ->(*, payload) do
      sum_queries += 1 if payload[:sql].to_s.match?(/SUM.*recurring_allocations/i)
    end

    entries = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      generator.send(:upcoming_recurring_flows, generator.send(:cash_accounts))
    end

    assert_equal 1, sum_queries, "the confirmed-allocation sums must batch into one grouped query"
    assert_equal [ -60, -100, -100 ], entries.sort_by(&:date).map(&:amount).map(&:to_i),
      "the partially paid occurrence contributes only its remainder"
  end

  # The feed is shared by the whole family: `connected` is private to
  # family_admin, so its balance must not cover the shared projection.
  test "a private cash account does not feed the projected balance" do
    accounts(:depository).update_columns(balance: 100)
    accounts(:connected).update_columns(balance: 50_000)

    insights = Insight::Generators::CashFlowWarningGenerator.new(@family).generate

    assert_equal 1, insights.size
    assert_equal Money.new(100, "USD").format, insights.first.facts[:current_balance]
  end

  test "bills paid from a private account are left out of the projection" do
    private_series = @family.recurring_transactions.create!(
      name: "Private Gym", account: accounts(:connected), amount: 70, currency: "USD",
      expected_day_of_month: 15, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true
    )
    private_series.recurring_occurrences.delete_all
    private_series.recurring_occurrences.create!(
      family: @family, original_due_on: Date.current + 2, due_on: Date.current + 2, currency: "USD"
    )

    assert_equal [ -100, -100, -60 ], flow_amounts
  end

  test "an inactive member does not hide an account from the projection" do
    users(:family_member).update_columns(active: false)
    accounts(:depository).update_columns(balance: 100)
    accounts(:connected).update_columns(balance: 50_000)

    assert_empty Insight::Generators::CashFlowWarningGenerator.new(@family).generate
  end

  test "scheduled income into a projected cash account lifts the projection" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(2_500)
    accounts(:depository).update_columns(balance: 1_500)
    schedule("Salary", -3_000, Date.current + 5)

    # Without the salary the 30-day baseline alone takes 1,500 to -1,000; with
    # it the low point is about 1,167, the day before it arrives.
    assert_empty generate
  end

  test "income into a private account does not cover the shared balance" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(2_500)
    accounts(:depository).update_columns(balance: 1_500)
    schedule("Private salary", -3_000, Date.current + 5, account: accounts(:connected))

    assert_equal [], flow_amounts
    assert_equal "cash_flow_warning.negative", generate.first.template_key
  end

  # The credit card is visible to every member, so the series passes the
  # shared-series scope; only the cash-account check keeps it out.
  test "income into a shared account that is not projected cash does not count" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(2_500)
    accounts(:depository).update_columns(balance: 1_500)
    schedule("Card refund", -3_000, Date.current + 5, account: accounts(:credit_card))

    assert_equal [], flow_amounts
    assert_equal "cash_flow_warning.negative", generate.first.template_key
  end

  # Out of the shared cash account, so only the transfer guard keeps it out.
  test "a scheduled transfer is not counted as a bill" do
    clear_schedule
    schedule("To card", 3_000, Date.current + 5, destination: accounts(:credit_card))

    assert_equal [], flow_amounts
  end

  test "a bill snoozed past the horizon is not projected on its original date" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(0)
    accounts(:depository).update_columns(balance: 1_000)
    schedule("Insurance", 800, Date.current + 3).snooze!(Date.current + 45)

    assert_empty generate
  end

  test "a bill snoozed past the horizon leaves the spending baseline" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(800)
    accounts(:depository).update_columns(balance: 1_000)
    schedule("Insurance", 800, Date.current + 3).snooze!(Date.current + 45)

    assert_empty generate
  end

  test "an overdue bill snoozed into the horizon counts on its new date" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(0)
    accounts(:depository).update_columns(balance: 1_000)
    schedule("Tax", 800, Date.current - 2).snooze!(Date.current + 4)

    insights = generate

    assert_equal 1, insights.size
    assert_equal I18n.l(Date.current + 4), insights.first.facts[:projected_low_date]
    assert_equal Money.new(200, "USD").format, insights.first.facts[:projected_low]
  end

  # The overdue occurrence belongs to last month; only next month's (day 25)
  # is part of the median, so only that one leaves the spending baseline.
  test "an overdue bill snoozed into the horizon is spent on top of the median" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(1_200)
    accounts(:depository).update_columns(balance: 1_500)
    series = schedule("Rent", 600, Date.current + 25).recurring_transaction
    series.recurring_occurrences.create!(
      family: @family, original_due_on: Date.current - 5, due_on: Date.current - 5, currency: "USD"
    ).snooze!(Date.current + 4)

    insight = generate.first

    # 1,500 - 600 (overdue) - 600 (next) - 600 (rest of the median) = -300.
    assert_equal "cash_flow_warning.negative", insight.template_key
    assert_equal Money.new(-300, "USD").format, insight.facts[:projected_low]
  end

  test "an overdue bill that was not snoozed is left out" do
    clear_schedule
    schedule("Tax", 800, Date.current - 2)

    assert_equal [], flow_amounts
  end

  # The bill may already be in today's balance, so it is not subtracted again,
  # but it stays in the spending baseline instead of vanishing from both.
  test "an open bill due today stays in the baseline" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(600)
    accounts(:depository).update_columns(balance: 1_000)
    schedule("Rent", 600, Date.current)

    insights = generate

    assert_equal 1, insights.size
    assert_equal Money.new(400, "USD").format, insights.first.facts[:projected_low]
  end

  test "open income due today counts from the start" do
    clear_schedule
    IncomeStatement.any_instance.stubs(:median_expense).returns(300)
    accounts(:depository).update_columns(balance: 100)
    schedule("Salary", -1_000, Date.current)

    assert_empty generate
  end

  private
    def generate
      Insight::Generators::CashFlowWarningGenerator.new(@family).generate
    end

    def flow_amounts
      generator = Insight::Generators::CashFlowWarningGenerator.new(@family)
      generator.send(:upcoming_recurring_flows, generator.send(:cash_accounts)).map { |flow| flow.amount.to_i }.sort
    end

    # Only the shared checking account holds cash, and only the series a test
    # schedules are open.
    def clear_schedule
      @family.recurring_transactions.destroy_all
      @family.accounts.where.not(id: accounts(:depository).id).where(accountable_type: "Depository").update_all(balance: 0)
    end

    def schedule(name, amount, due_on, account: accounts(:depository), destination: nil)
      series = @family.recurring_transactions.create!(
        name: name, account: account, destination_account: destination, amount: amount, currency: "USD",
        expected_day_of_month: 15, last_occurrence_date: Date.current,
        next_expected_date: 1.month.from_now.to_date, status: "active", manual: true
      )
      series.recurring_occurrences.delete_all
      series.recurring_occurrences.create!(family: @family, original_due_on: due_on, due_on: due_on, currency: "USD")
    end
end
