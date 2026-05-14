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
    assert_includes new_goal.errors[:linked_accounts], "All linked accounts must be depository (checking, savings, HSA, CD, money-market)."
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

  test "currency can't change once linked accounts exist" do
    assert @goal.linked_accounts.exists?
    @goal.currency = "EUR"
    assert_not @goal.valid?
    assert_includes @goal.errors[:currency], "Can't change the currency after the goal is linked to accounts."
  end

  test "current_balance sums linked account balances" do
    expected = @goal.linked_accounts.sum(&:balance).to_d
    assert_equal expected, @goal.current_balance.to_d
  end

  test "progress_percent caps at 100" do
    @goal.target_amount = 1
    assert_equal 100, @goal.progress_percent
  end

  test "progress_percent is 0 for empty active goal" do
    fresh = goals(:car_paydown)
    fresh.target_amount = 10_000
    fresh.linked_accounts.update_all(balance: 0)
    fresh.instance_variable_set(:@current_balance, nil)
    fresh.linked_accounts.reload
    assert_equal 0, fresh.progress_percent
  end

  test "remaining_amount is non-negative" do
    @goal.target_amount = 1
    assert_equal 0, @goal.remaining_amount
  end

  test "pace is zero on a goal whose linked accounts have no transactions" do
    fresh_account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Empty Savings",
      currency: "USD",
      balance: 0
    )
    fresh = @family.goals.create!(
      name: "Fresh goal",
      target_amount: 100,
      currency: "USD"
    ) { |g| g.goal_accounts.build(account: fresh_account) }

    assert_equal 0, fresh.pace.to_d
  end

  test "months_of_runway is nil when goal has a target date" do
    assert_not_nil @goal.target_date
    assert_nil @goal.months_of_runway
  end

  test "months_of_runway is nil when pace is zero" do
    fresh = goals(:emergency_fund)
    assert_nil fresh.months_of_runway
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
    @goal.linked_accounts.update_all(balance: 100)
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

  test "any_connected_account? reflects plaid_account presence" do
    assert @goal.any_connected_account?
    only_manual = goals(:emergency_fund)
    only_manual.goal_accounts.where(account_id: @connected.id).destroy_all
    assert_not only_manual.reload.any_connected_account?
  end

  test "pledge_action_label_key flips on manual-only goals" do
    assert_equal "goals.show.pledge_just_transferred", @goal.pledge_action_label_key
    @goal.goal_accounts.where(account_id: @connected.id).destroy_all
    @goal.reload
    @goal.instance_variable_set(:@current_balance, nil)
    assert_equal "goals.show.pledge_just_transferred", @goal.pledge_action_label_key if @goal.linked_accounts.any?(&:plaid_account)
  end
end
