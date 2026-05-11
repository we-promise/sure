require "test_helper"

class GoalTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @depository = accounts(:depository)
    @connected = accounts(:connected)
    @goal = goals(:vacation_italy)
  end

  test "valid fixture goal saves" do
    assert @goal.valid?
  end

  test "name is required" do
    @goal.name = ""
    assert_not @goal.valid?
    assert_includes @goal.errors[:name], "can't be blank"
  end

  test "target_amount must be positive" do
    @goal.target_amount = 0
    assert_not @goal.valid?
  end

  test "must have at least one linked account on create" do
    new_goal = @family.goals.new(name: "Test", target_amount: 100, currency: "USD")
    assert_not new_goal.valid?
    assert_match(/at least one/i, new_goal.errors[:base].join)
  end

  test "linked accounts must be depository" do
    investment = accounts(:investment)
    new_goal = @family.goals.new(name: "Test", target_amount: 100, currency: "USD")
    new_goal.goal_accounts.build(account: investment)
    assert_not new_goal.valid?
    assert_includes new_goal.errors[:linked_accounts], "All linked accounts must be Depository (checking, savings, HSA, CD, money-market)."
  end

  test "linked accounts must belong to family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign_account = Account.create!(
      family: other_family,
      accountable: Depository.new,
      name: "Foreign",
      currency: "USD",
      balance: 100
    )
    new_goal = @family.goals.new(name: "T", target_amount: 100, currency: "USD")
    new_goal.goal_accounts.build(account: foreign_account)
    assert_not new_goal.valid?
    assert_includes new_goal.errors[:linked_accounts], "Linked accounts must belong to the same family as the goal."
  end

  test "linked accounts must share currency with goal" do
    eur_account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Euro Cash",
      currency: "EUR",
      balance: 100
    )
    new_goal = @family.goals.new(name: "T", target_amount: 100, currency: "USD")
    new_goal.goal_accounts.build(account: eur_account)
    assert_not new_goal.valid?
    assert_includes new_goal.errors[:linked_accounts], "All linked accounts must share the same currency."
  end

  test "currency can't change after contributions exist" do
    assert @goal.goal_contributions.exists?
    @goal.currency = "EUR"
    assert_not @goal.valid?
    assert_includes @goal.errors[:currency], "Can't change the currency after a goal has contributions."
  end

  test "current_balance sums contributions" do
    expected = @goal.goal_contributions.sum(:amount)
    assert_equal expected, @goal.current_balance
  end

  test "with_current_balance scope precomputes balance" do
    loaded = @family.goals.with_current_balance.find(@goal.id)
    expected = @goal.goal_contributions.sum(:amount)
    assert_equal expected.to_f, loaded.current_balance.to_f
  end

  test "progress_percent caps at 100" do
    @goal.target_amount = 1
    assert_equal 100, @goal.progress_percent
  end

  test "progress_percent is 0 for empty active goal" do
    fresh = goals(:car_paydown)
    fresh.target_amount = 10000
    assert_equal 0, fresh.progress_percent
  end

  test "remaining_amount is non-negative" do
    @goal.target_amount = 1
    assert_equal 0, @goal.remaining_amount
  end

  test "AASM transitions" do
    fresh = goals(:emergency_fund)
    assert fresh.active?
    fresh.pause!
    assert fresh.paused?
    fresh.resume!
    assert fresh.active?
    fresh.complete!
    assert fresh.completed?
    fresh.archive!
    assert fresh.archived?
    fresh.unarchive!
    assert fresh.active?
  end

  test "status: reached when balance >= target" do
    @goal.target_amount = 1
    assert_equal :reached, @goal.status
  end

  test "status: no_target_date when target_date is nil" do
    @goal.target_date = nil
    @goal.target_amount = 10_000
    assert_equal :no_target_date, @goal.status
  end

  test "display_status returns :archived for archived goal regardless of progress" do
    @goal.save!
    @goal.archive!
    assert_equal :archived, @goal.display_status
  end

  test "display_status returns :paused for paused goal regardless of progress" do
    @goal.save!
    @goal.pause!
    assert_equal :paused, @goal.display_status
  end

  test "display_status falls through to status for active goals" do
    @goal.target_amount = 1
    assert_equal :reached, @goal.display_status
  end

  test "advisory_lock_key_for is stable per family" do
    k1 = Goal.advisory_lock_key_for(@family.id)
    k2 = Goal.advisory_lock_key_for(@family.id)
    assert_equal k1, k2
    assert_kind_of Integer, k1
  end
end
