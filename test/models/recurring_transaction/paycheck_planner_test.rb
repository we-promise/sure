require "test_helper"

class RecurringTransaction::PaycheckPlannerTest < ActiveSupport::TestCase
  Planner = RecurringTransaction::PaycheckPlanner

  def setup
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
  end

  test "no declared income means no plan" do
    create_series(name: "Rent", amount: 2150, due: Date.current + 10)

    assert_nil Planner.new(@family, user: @user).plan
  end

  test "auto-detected inflows never define paydays" do
    penny = create_series(name: "To Car Vault", amount: -0.01, due: Date.current + 2, income: true)
    penny.update!(manual: false)
    create_series(name: "Rent", amount: 2150, due: Date.current + 10)

    assert_nil Planner.new(@family, user: @user).plan,
               "a recurring one-cent transfer is income by sign and a paycheck by nothing"
  end

  test "periods slice by paycheck and apportion bills to their due dates" do
    first_payday = Date.current + 3
    create_series(name: "Paycheck", amount: -1840, due: first_payday, preset: "weekly", income: true)
    rent_due = Date.current + 17
    rent = create_series(name: "Rent", amount: 2150, due: rent_due)
    create_series(name: "Internet", amount: 90, due: Date.current + 5)

    plan = Planner.new(@family, user: @user).plan(periods_limit: 3)

    assert_equal 4, plan.size, "today-to-first-paycheck plus three paychecks"
    assert_equal Date.current, plan.first.starts_on
    assert_equal 0, plan.first.income
    assert_equal 1840, plan[1].income

    rent_shares = plan.flat_map(&:items).select { |item| item.occurrence.recurring_transaction_id == rent.id }
    eligible = plan.count { |period| period.starts_on <= rent_due }
    assert_equal eligible, rent_shares.size, "rent spreads across every period before its due date"
    assert_equal 2150, rent_shares.sum(&:share), "shares reassemble the full obligation exactly"
    assert_equal 1, rent_shares.count(&:due_in_period)

    plan.each do |period|
      assert_equal period.income - period.obligation_total, period.remaining
    end
  end

  test "partial payments shrink the apportioned obligation" do
    create_series(name: "Paycheck", amount: -2000, due: Date.current + 2, preset: "weekly", income: true)
    rent = create_series(name: "Rent", amount: 2150, due: Date.current + 9)
    occurrence = rent.recurring_occurrences.order(:due_on).first
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: "1075")

    plan = Planner.new(@family, user: @user).plan
    rent_total = plan.flat_map(&:items)
                     .select { |item| item.occurrence.recurring_transaction_id == rent.id }
                     .sum(&:share)

    assert_equal 1075, rent_total, "only the remaining balance needs setting aside"
  end

  private
    def create_series(name:, amount:, due:, preset: "monthly", income: false)
      series = @family.recurring_transactions.create!(
        name: name,
        account: @account,
        amount: amount,
        currency: "USD",
        bill_type: income ? "income" : "bill",
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: true
      )

      if preset != "monthly"
        RecurringTransaction::FrequencyPreset.apply(series, preset: preset, weekday: due.wday)
        series.save!
      end

      series
    end
end
