require "test_helper"

class GoalAccountTest < ActiveSupport::TestCase
  setup do
    @goal = goals(:emergency_fund)
    @account = Account.create!(
      family: families(:dylan_family),
      accountable: Depository.new,
      name: "Allocation Test",
      currency: "USD",
      balance: 1_000
    )
  end

  test "allocated_amount may be nil, meaning dedicate the whole balance" do
    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: nil)
    assert ga.valid?, ga.errors.full_messages.to_sentence
    assert ga.whole_account?
  end

  test "a set allocated_amount is not a whole-account link" do
    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: 250)
    assert ga.valid?, ga.errors.full_messages.to_sentence
    assert_not ga.whole_account?
  end

  test "allocated_amount must be non-negative" do
    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: -1)
    assert_not ga.valid?
    assert_includes ga.errors[:allocated_amount], "must be greater than or equal to 0"
  end

  # --- whole-account exclusivity (see GoalAccount#whole_account_link_must_be_exclusive) ---

  test "a second whole-account link on an already fully-earmarked account is rejected" do
    goals(:vacation_italy).goal_accounts.create!(account: @account)

    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: nil)

    assert_not ga.valid?
    assert_includes ga.errors[:base].first, "Vacation in Italy"
  end

  test "a fixed earmark is always allowed on an account another goal claims whole" do
    goals(:vacation_italy).goal_accounts.create!(account: @account)

    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: 250)

    assert ga.valid?, ga.errors.full_messages.to_sentence
  end

  test "a whole-account link is allowed when the other goal earmarks a fixed slice" do
    goals(:vacation_italy).goal_accounts.create!(account: @account, allocated_amount: 250)

    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: nil)

    assert ga.valid?, ga.errors.full_messages.to_sentence
  end

  # The guard tracks Goal.pooled_allocations_for, which excludes archived goals
  # from the backing math. Money held by an archived goal is not claimed, so it
  # must not block a live one.
  test "an archived goal's whole-account link does not block a new one" do
    other = goals(:vacation_italy)
    other.goal_accounts.create!(account: @account)
    other.archive!

    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: nil)

    assert ga.valid?, ga.errors.full_messages.to_sentence
  end

  # A completed goal still holds its money and still feeds the pool, so unlike
  # an archived one it does claim the balance.
  test "a completed goal's whole-account link still blocks a new one" do
    other = goals(:vacation_italy)
    other.goal_accounts.create!(account: @account)
    other.complete!

    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: nil)

    assert_not ga.valid?
  end

  test "another family's whole-account link on its own account is irrelevant" do
    foreign_family = families(:empty)
    foreign_account = Account.create!(
      family: foreign_family, accountable: Depository.new,
      name: "Their Checking", currency: "USD", balance: 1_000
    )
    foreign_family.goals.create!(
      name: "Theirs", target_amount: 500, currency: "USD",
      goal_accounts: [ GoalAccount.new(account: foreign_account) ]
    )

    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: nil)

    assert ga.valid?, ga.errors.full_messages.to_sentence
  end

  test "re-saving an existing whole-account link does not trip on itself" do
    ga = @goal.goal_accounts.create!(account: @account)

    assert ga.valid?, ga.errors.full_messages.to_sentence
    assert ga.reload.update(updated_at: Time.current)
  end

  # Autosave revalidates every loaded goal_account on goal.save. A goal that
  # merely holds an overlap written before this guard existed must stay
  # editable — otherwise renaming it becomes impossible.
  test "a legacy overlap does not block an unrelated edit to the goal holding it" do
    other = goals(:vacation_italy)
    other.goal_accounts.create!(account: @account)
    legacy = @goal.goal_accounts.create!(account: @account, allocated_amount: 1)
    legacy.update_column(:allocated_amount, nil)

    @goal.reload.name = "Renamed"

    assert @goal.save, @goal.errors.full_messages.to_sentence
  end

  # ...but deliberately clearing an amount on a contested account is a new
  # claim on the whole balance, so it is refused.
  test "clearing a fixed earmark onto a contested account is refused" do
    goals(:vacation_italy).goal_accounts.create!(account: @account)
    ga = @goal.goal_accounts.create!(account: @account, allocated_amount: 250)

    ga.allocated_amount = nil

    assert_not ga.valid?
  end

  # Moving a whole-account link is a fresh claim on wherever it lands. It is
  # neither new nor allocation-dirty, so the two original predicates let it
  # through onto an account nobody had checked.
  test "moving a whole-account link onto a contested account is refused" do
    contested = Account.create!(
      family: families(:dylan_family), accountable: Depository.new,
      name: "Contested", currency: "USD", balance: 4_000
    )
    goals(:vacation_italy).goal_accounts.create!(account: contested)
    mine = @goal.goal_accounts.create!(account: @account, allocated_amount: nil)

    mine.account = contested

    assert_not mine.valid?
    assert_includes mine.errors.full_messages.to_sentence, goals(:vacation_italy).name
  end

  test "moving a whole-account link onto a free account is allowed" do
    free = Account.create!(
      family: families(:dylan_family), accountable: Depository.new,
      name: "Free", currency: "USD", balance: 4_000
    )
    mine = @goal.goal_accounts.create!(account: @account, allocated_amount: nil)

    mine.account = free

    assert mine.valid?, mine.errors.full_messages.to_sentence
  end

  # The bound still has to let a row that is merely along for the ride pass:
  # autosave revalidates every loaded child on goal.save.
  test "a legacy overlap still does not block an unrelated edit after the widening" do
    other = goals(:vacation_italy)
    other.goal_accounts.create!(account: @account)
    legacy = @goal.goal_accounts.create!(account: @account, allocated_amount: 1)
    legacy.update_column(:allocated_amount, nil)

    @goal.reload.name = "Renamed again"

    assert @goal.save, @goal.errors.full_messages.to_sentence
  end
end
