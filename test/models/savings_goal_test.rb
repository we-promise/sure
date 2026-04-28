require "test_helper"

class SavingsGoalTest < ActiveSupport::TestCase
  setup do
    @goal = savings_goals(:vacation)
  end

  test "valid fixture" do
    assert @goal.valid?
  end

  test "requires name and target_amount (currency is derived from account)" do
    goal = SavingsGoal.new(family: families(:dylan_family), account: accounts(:depository))
    assert_not goal.valid?
    assert_includes goal.errors.attribute_names, :name
    assert_includes goal.errors.attribute_names, :target_amount
  end

  test "rejects non-positive target_amount" do
    @goal.target_amount = 0
    assert_not @goal.valid?
    @goal.target_amount = -50
    assert_not @goal.valid?
  end

  test "starts in active state" do
    goal = SavingsGoal.create!(
      family: families(:dylan_family),
      account: accounts(:depository),
      name: "New goal",
      target_amount: 100
    )
    assert goal.active?
  end

  test "lifecycle transitions" do
    @goal.pause!
    assert @goal.paused?
    @goal.resume!
    assert @goal.active?
    @goal.complete!
    assert @goal.completed?
    @goal.archive!
    assert @goal.archived?
    @goal.unarchive!
    assert @goal.active?
  end

  test "current_balance sums contributions" do
    assert_equal 1250.00, @goal.current_balance
  end

  test "remaining_amount clamps to zero when over target" do
    SavingsContribution.create!(
      savings_goal: @goal, amount: 10_000, currency: "USD",
      source: "manual", contributed_at: Date.current
    )
    assert_equal 0, @goal.remaining_amount
  end

  test "progress_percent caps at 100" do
    assert_operator @goal.progress_percent, :<=, 100
  end

  test "progress_percent is 100 once completed" do
    assert_equal 100, savings_goals(:paid_off_car).progress_percent
  end

  test "months_remaining nil when no target_date" do
    assert_nil savings_goals(:paid_off_car).months_remaining
  end

  test "monthly_target_amount nil when no target_date" do
    assert_nil savings_goals(:paid_off_car).monthly_target_amount
  end

  test "advisory_lock_key_for is stable per family and distinct across families" do
    assert_equal SavingsGoal.advisory_lock_key_for(42), SavingsGoal.advisory_lock_key_for(42)
    assert_not_equal SavingsGoal.advisory_lock_key_for(42), SavingsGoal.advisory_lock_key_for(43)
    key = SavingsGoal.advisory_lock_key_for(42)
    assert_kind_of Integer, key
    assert_operator key, :>=, 0
    assert_operator key, :<, 2**63
  end

  test "monthly_target_amount divides remaining by months" do
    @goal.target_date = 5.months.from_now.to_date
    expected = (@goal.remaining_amount.to_d / @goal.months_remaining).ceil(2)
    assert_equal expected, @goal.monthly_target_amount
  end

  test "name length capped at 255" do
    @goal.name = "x" * 256
    assert_not @goal.valid?
    assert_includes @goal.errors.attribute_names, :name

    @goal.name = "x" * 255
    assert @goal.valid?
  end

  test "progress_percent caps at 100 when over-funded" do
    @goal.savings_contributions.create!(
      amount: @goal.target_amount * 2,
      currency: @goal.currency,
      source: "manual",
      contributed_at: Date.current
    )
    assert_equal 100, @goal.progress_percent
  end

  test "remaining_amount clamps at zero when over-funded" do
    @goal.savings_contributions.create!(
      amount: @goal.target_amount * 2,
      currency: @goal.currency,
      source: "manual",
      contributed_at: Date.current
    )
    assert_equal 0, @goal.remaining_amount
  end

  test "monthly_target_amount returns full remaining when target_date is in the past" do
    @goal.target_date = 1.month.ago.to_date
    assert_equal 0, @goal.months_remaining
    assert_equal @goal.remaining_amount, @goal.monthly_target_amount
  end

  test "currency cannot be changed via account swap once contributions exist" do
    eur_account = @goal.family.accounts.create!(
      name: "Euro Pot", balance: 0, currency: "EUR",
      accountable: Depository.new
    )
    # @goal already has fixture contributions in USD
    @goal.account = eur_account
    assert_not @goal.valid?
    assert_includes @goal.errors.attribute_names, :account
  end

  test "currency may be changed via account swap when there are no contributions yet" do
    eur_account = @goal.family.accounts.create!(
      name: "Euro Pot", balance: 0, currency: "EUR",
      accountable: Depository.new
    )
    @goal.savings_contributions.delete_all
    @goal.account = eur_account
    assert @goal.valid?, @goal.errors.full_messages.to_sentence
  end

  test "destroy cascades contributions" do
    contribution_ids = @goal.savings_contributions.pluck(:id)
    @goal.destroy
    assert_equal 0, SavingsContribution.where(id: contribution_ids).count
  end

  test "is destroyed when its backing account is destroyed" do
    account = @goal.account
    goal_id = @goal.id
    contribution_ids = @goal.savings_contributions.pluck(:id)
    account.destroy
    assert_nil SavingsGoal.find_by(id: goal_id)
    assert_equal 0, SavingsContribution.where(id: contribution_ids).count
  end
end

class SavingsGoalAccountLinkTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  test "requires an account" do
    goal = SavingsGoal.new(family: @family, name: "x", target_amount: 100)
    assert_not goal.valid?
    assert_includes goal.errors.attribute_names, :account
  end

  test "rejects accounts from other families" do
    other_family = Family.create!(name: "Other", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    goal = SavingsGoal.new(family: other_family, account: @account, name: "x", target_amount: 100)
    assert_not goal.valid?
    assert_includes goal.errors.attribute_names, :account
  end

  test "rejects liability accounts" do
    liability = accounts(:other_liability)
    goal = SavingsGoal.new(family: @family, account: liability, name: "x", target_amount: 100)
    assert_not goal.valid?
    assert_includes goal.errors.attribute_names, :account
  end

  test "syncs currency from account on save" do
    goal = SavingsGoal.create!(family: @family, account: @account, name: "x", target_amount: 100)
    assert_equal @account.currency, goal.currency
  end
end
