require "test_helper"

# M2 PR#2b: the income's hard bank-link limit (plan_max_account_links). At
# plan time the planner raises a warning, never an error; the model only
# enforces "positive integer when set".
class RecurringTransactionPlanLimitsTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @account = accounts(:depository)
    @series = @family.recurring_transactions.create!(
      name: "Payroll",
      account: @account,
      amount: 100,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      status: "active",
      bill_type: "income",
      manual: true
    )
  end

  test "plan_max_account_links is a positive integer or unset" do
    assert @series.valid?
    @series.plan_max_account_links = 4
    assert @series.valid?
    @series.plan_max_account_links = 0
    assert_not @series.valid?
    assert @series.errors[:plan_max_account_links].any?
    @series.plan_max_account_links = nil
    assert @series.valid?
  end
end
