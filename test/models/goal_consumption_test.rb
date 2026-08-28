require "test_helper"

# Lot B4: recording that a goal's money was spent on what it was for.
class GoalConsumptionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "spending a goal's money does not look like falling behind" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    assert_equal 100, goal.progress_percent

    goal.consume!(3_000)

    assert_equal 3_000, goal.consumed_amount
    assert_equal 100, goal.progress_percent, "spent money still counts toward the target"
    assert_equal 0, goal.remaining_amount
  end

  # The part that is easy to miss: money already spent must stop being
  # reserved, or it keeps its share of the account away from sibling goals.
  test "consuming shrinks the earmark by the same amount" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)

    goal.consume!(2_000)

    assert_equal 3_000, goal.goal_accounts.first.reload.allocated_amount
  end

  # Deliberately over-earmarked, which is the normal state of a shared account
  # mid-saving: 10,000 claimed on 6,000 held, so the pro-rata haircut is in
  # play and both goals read 3,000. Releasing spent money relieves the haircut
  # and the sibling's share grows — where two plain fixed earmarks inside the
  # balance would each just take their own amount and nothing would move.
  test "the freed share relieves the haircut on a sibling goal" do
    account = fresh_account(6_000)
    mine = goal_on(account, earmark: 5_000, target: 5_000, name: "Trip")
    sibling = goal_on(account, earmark: 5_000, target: 5_000, name: "Sibling")

    before = Goal.find(sibling.id).current_balance.to_d
    assert_equal 3_000, before, "the fixture should start out haircut"

    mine.consume!(2_000)

    assert_equal 3_750, Goal.find(sibling.id).current_balance.to_d
  end

  # A whole-account link has no slice to shrink, so the consumption used to be
  # recorded against a backing that had not moved — the goal reading 6,000 of
  # 5,000 until the real transaction landed and the balance caught up. A fixed
  # earmark never has that window, because shrinking it caps the backing at
  # once.
  #
  # Spending settles what the link claims: it stops taking "whatever is there"
  # and takes what is left after the spend.
  test "spending from a whole-account link settles what it claims" do
    account = fresh_account(5_000)
    goal = @family.goals.create!(name: "Whole", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    goal.consume!(1_000)

    assert_equal 1_000, goal.consumed_amount
    assert_equal 4_000, goal.goal_accounts.first.reload.allocated_amount.to_d,
      "the link still claimed the whole account after part of it was spent"
  end

  # The figure that gave this away: held plus spent overshooting the target
  # while the account had not moved yet.
  test "a whole-account goal does not count the same money twice" do
    account = fresh_account(5_000)
    goal = @family.goals.create!(name: "Whole", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    goal.consume!(1_000)

    assert_equal 5_000, goal.current_balance.to_d + goal.consumed_amount.to_d
  end

  # The order the two events arrive in is not fixed. A spend recorded before
  # the sync lands needs the account's fall accounted for; the same spend
  # recorded after it has already had it, and subtracting twice reported
  # 4,000 of a 5,000 goal that was whole. Capping at what is left to reach is
  # the same answer either way.
  test "it is right when the balance falls before the spend is recorded" do
    account = fresh_account(4_000)
    goal = @family.goals.create!(name: "Late", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    goal.consume!(1_000)

    assert_equal 5_000, goal.current_balance.to_d + goal.consumed_amount.to_d
  end

  # A goal holding more than it needs keeps counting only toward its target
  # once it has spent something — the cap is what makes the two orders agree,
  # and it applies the same way here.
  test "a goal holding more than its target settles at its target" do
    account = fresh_account(7_000)
    goal = @family.goals.create!(name: "Over", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    goal.consume!(1_000)

    assert_equal 5_000, goal.current_balance.to_d + goal.consumed_amount.to_d
  end

  # And it stays right once the spend actually lands, which is the state a
  # fixed earmark has always handled and this one did not.
  test "it is still right once the balance catches up" do
    account = fresh_account(5_000)
    goal = @family.goals.create!(name: "Whole", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    goal.consume!(1_000)

    account.update!(balance: 4_000)
    settled = Goal.find(goal.id)

    assert_equal 5_000, settled.current_balance.to_d + settled.consumed_amount.to_d
  end

  # Nothing to take it from: the refusal is the same one a fixed earmark gives
  # when the amount is larger than the slice.
  test "spending more than the goal has left to reach is refused" do
    account = fresh_account(1_000)
    goal = @family.goals.create!(name: "Whole", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    error = assert_raises(Goal::ConsumptionRefused) { goal.consume!(2_000) }

    assert_equal :exceeds_earmark, error.reason
    assert_equal 0, goal.reload.consumed_amount
  end

  test "with several linked accounts the caller has to say which one" do
    goal = goal_with(earmark: 3_000, balance: 3_000, target: 6_000)
    goal.goal_accounts.create!(account: fresh_account(3_000), allocated_amount: 3_000)

    error = assert_raises(Goal::ConsumptionRefused) { goal.consume!(1_000) }
    assert_equal :account_required, error.reason
  end

  test "naming one of the linked accounts is enough" do
    goal = goal_with(earmark: 3_000, balance: 3_000, target: 6_000)
    second = fresh_account(3_000)
    goal.goal_accounts.create!(account: second, allocated_amount: 3_000)

    goal.consume!(1_000, account: second)

    assert_equal 2_000, goal.goal_accounts.find_by(account_id: second.id).reload.allocated_amount
  end

  test "an account the goal is not linked to is refused" do
    goal = goal_with(earmark: 3_000, balance: 3_000, target: 5_000)

    error = assert_raises(Goal::ConsumptionRefused) { goal.consume!(500, account: fresh_account(100)) }
    assert_equal :account_not_linked, error.reason
  end

  test "consuming more than the goal ever set out to save is refused" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)

    error = assert_raises(Goal::ConsumptionRefused) { goal.consume!(5_001) }
    assert_equal :exceeds_target, error.reason
    assert_equal 0, goal.reload.consumed_amount
  end

  test "a non-positive amount is refused" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)

    assert_equal :non_positive, assert_raises(Goal::ConsumptionRefused) { goal.consume!(0) }.reason
  end

  # A reserve is drawn down and refilled, not consumed. Recording a withdrawal
  # as consumption would erase the shortfall the reserve exists to report.
  test "a reserve refuses consumption outright" do
    account = fresh_account(4_000)
    reserve = @family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: "USD", kind: "maintained"
    ) { |g| g.goal_accounts.build(account: account) }

    error = assert_raises(Goal::ConsumptionRefused) { reserve.consume!(1_000) }
    assert_equal :maintained, error.reason
  end

  test "reopening a goal clears what was spent under its previous life" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    goal.consume!(2_000)
    goal.complete!

    goal.reload.reopen!

    assert_equal 0, goal.reload.consumed_amount
  end

  # `completed_amount` freezes the BACKING; consumption is counted separately.
  # Folding one into the other would count the same money twice on a goal that
  # was partly spent and then closed.
  test "closing after a partial spend counts each side once" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    goal.consume!(2_000)

    goal.complete!

    reloaded = Goal.find(goal.id)
    assert_equal 3_000, reloaded.completed_amount, "the frozen figure is the backing alone"
    assert_equal 2_000, reloaded.consumed_amount
    assert_equal 0, reloaded.remaining_amount
  end

  # --- Review follow-ups ---

  # Clamping released only what the link held while `consumed_amount` took the
  # full figure, so the two sides silently disagreed: money counted as spent
  # that was never released, and still reserved against every sibling.
  test "consuming more than the chosen link holds is refused, not clamped" do
    goal = goal_with(earmark: 3_000, balance: 6_000, target: 9_000)
    second = fresh_account(6_000)
    goal.goal_accounts.create!(account: second, allocated_amount: 1_000)

    error = assert_raises(Goal::ConsumptionRefused) { goal.consume!(2_000, account: second) }

    assert_equal :exceeds_earmark, error.reason
    assert_equal 0, goal.reload.consumed_amount
    assert_equal 1_000, goal.goal_accounts.find_by(account_id: second.id).reload.allocated_amount
  end

  # A dialog left open in another tab, or a client posting directly.
  test "a goal that is no longer active records nothing" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    goal.complete!

    error = assert_raises(Goal::ConsumptionRefused) { goal.reload.consume!(1_000) }

    assert_equal :not_active, error.reason
    assert_equal 0, goal.reload.consumed_amount
  end

  # A reserve refuses consumption, so a converted goal would carry a figure
  # counting toward progress on an object whose model says spending is a
  # shortfall to refill. The two readings cannot both be true.
  test "a goal that has recorded a spend cannot become a reserve" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    goal.consume!(1_000)

    goal.kind = "maintained"

    assert_not goal.valid?
    assert_includes goal.errors[:kind],
                    "This goal has already recorded money as spent, so it cannot become a reserve."
  end

  # The consumed total was only checked while consuming, leaving the ordinary
  # edit form free to lower the target underneath it.
  test "the target cannot be lowered below what was already spent" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    goal.consume!(3_000)

    assert_not goal.update(target_amount: 2_000)
    assert_equal 5_000, goal.reload.target_amount
  end

  # `reload` refreshes columns and leaves memos standing, so an instance that
  # had already read its backing kept reporting the figure from before the
  # spend — while progress, which nets the two, looked unchanged and hid it.
  #
  # Progress holding at 50% is not the bug, it is the feature: the earmark
  # shrinks by exactly what consumption grows by, so spending the money does
  # not move the bar. The backing underneath it does move, and must say so.
  test "the figures an instance already read are refreshed by consuming" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 10_000)
    assert_equal 5_000, goal.current_balance.to_d
    assert_equal 50, goal.progress_percent

    goal.consume!(2_000)

    assert_equal 3_000, goal.current_balance.to_d, "the memo survived the spend"
    assert_equal 50, goal.progress_percent, "and progress is preserved, which is the point"
  end

  # Restarting a goal drops what it spent under its previous life, along with
  # the frozen figure. A goal archived straight from active never froze one —
  # unarchiving it is picking the same goal back up, not restarting it.
  test "unarchiving a goal that never completed keeps what it spent" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    goal.consume!(1_000)
    goal.archive!

    goal.unarchive!

    assert_equal 1_000, goal.reload.consumed_amount
  end

  test "reopening a completed goal starts it over" do
    goal = goal_with(earmark: 5_000, balance: 5_000, target: 5_000)
    goal.consume!(1_000)
    goal.complete!

    goal.reopen!

    assert_equal 0, goal.reload.consumed_amount
  end

  private
    def fresh_account(balance)
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "Pot #{SecureRandom.hex(4)}", currency: "USD", balance: balance
      )
    end

    def goal_on(account, earmark:, target:, name:)
      @family.goals.create!(name: name, target_amount: target, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: earmark)
      end
    end

    def goal_with(earmark:, balance:, target:)
      goal_on(fresh_account(balance), earmark: earmark, target: target, name: "Trip #{SecureRandom.hex(4)}")
    end
end
