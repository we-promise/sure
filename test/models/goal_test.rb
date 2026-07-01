require "test_helper"

class GoalTest < ActiveSupport::TestCase
  include EntriesTestHelper

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

  test "color must match hex format" do
    @goal.color = "red; cursor: pointer"
    assert_not @goal.valid?
    assert_includes @goal.errors[:color], "is invalid"
  end

  test "color accepts standard 6-digit hex" do
    @goal.color = "#abcdef"
    assert @goal.valid?, @goal.errors.full_messages.to_sentence
  end

  test "display_status follows AASM state after pause! on the same instance" do
    @goal.update!(color: "#4da568") if @goal.color.blank?
    initial = @goal.display_status
    @goal.pause!
    assert_equal :paused, @goal.display_status, "stale memo would have returned #{initial.inspect}"
  end

  test "must have at least one linked account on create" do
    new_goal = @family.goals.new(name: "Test", target_amount: 100, currency: "USD")
    assert_not new_goal.valid?
    assert_match(/at least one/i, new_goal.errors[:base].join)
  end

  test "investment accounts are fundable and default to the contributions basis" do
    investment = accounts(:investment)
    new_goal = @family.goals.new(name: "Inv", target_amount: 100, currency: "USD")
    new_goal.goal_accounts.build(account: investment)
    assert new_goal.valid?, new_goal.errors.full_messages.to_sentence
    new_goal.save! # basis is set on save (before_save), not on valid?
    assert_equal "contributions", new_goal.progress_basis
  end

  test "non-fundable account types are rejected" do
    credit = accounts(:credit_card)
    new_goal = @family.goals.new(name: "Test", target_amount: 100, currency: "USD")
    new_goal.goal_accounts.build(account: credit)
    assert_not new_goal.valid?
    assert_includes new_goal.errors[:linked_accounts], "All linked accounts must be cash or investment accounts."
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

  test "progress_percent stays below 100 while remaining amount is positive" do
    account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Almost There Savings",
      currency: "USD",
      balance: BigDecimal("999.50")
    )

    goal = @family.goals.create!(
      name: "Almost There",
      target_amount: BigDecimal("1000"),
      currency: "USD"
    ) { |new_goal| new_goal.goal_accounts.build(account: account) }

    assert_equal BigDecimal("0.5"), goal.remaining_amount
    assert_equal 99, goal.progress_percent
    assert_equal :no_target_date, goal.status
  end

  test "status stays reached for a goal completed while underfunded" do
    account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Completed Underfunded Savings",
      currency: "USD",
      balance: BigDecimal("999.50")
    )

    goal = @family.goals.create!(
      name: "Completed Underfunded",
      target_amount: BigDecimal("1000"),
      currency: "USD"
    ) { |new_goal| new_goal.goal_accounts.build(account: account) }

    goal.complete!

    assert_equal BigDecimal("0.5"), goal.remaining_amount
    assert_equal 100, goal.progress_percent
    assert_equal :reached, Goal.find(goal.id).status
  end

  test "progress_percent is 0 for empty active goal" do
    fresh = goals(:car_paydown)
    fresh.update!(target_amount: 10_000)
    fresh.linked_accounts.update_all(balance: 0)
    # Refetch instead of poking @current_balance directly so the test
    # exercises the real memo lifecycle (a request reads progress_percent
    # on a freshly-loaded record after the underlying balances changed).
    reloaded = Goal.find(fresh.id)
    assert_equal 0, reloaded.progress_percent
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

  test "pace averages 90-day net inflow, excluding pending and excluded entries" do
    account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Pace Savings",
      currency: "USD",
      balance: 0
    )
    goal = @family.goals.create!(
      name: "Pace goal",
      target_amount: 10_000,
      currency: "USD"
    ) { |g| g.goal_accounts.build(account: account) }

    # Three inflows over the 90-day window. Sure convention: inflows are
    # negative. Net = -900 → pace = 900 / 3 = 300.
    create_transaction(account: account, amount: -300, date: 80.days.ago.to_date)
    create_transaction(account: account, amount: -300, date: 40.days.ago.to_date)
    create_transaction(account: account, amount: -300, date: 5.days.ago.to_date)

    # Pending inflow that must be excluded by `Transaction.excluding_pending`.
    pending_entry = create_transaction(account: account, amount: -1_000, date: 10.days.ago.to_date)
    pending_entry.transaction.update!(extra: { "plaid" => { "pending" => true } })

    # User-excluded outflow that must be excluded by `entries.excluded = false`.
    excluded_entry = create_transaction(account: account, amount: 500, date: 20.days.ago.to_date)
    excluded_entry.update!(excluded: true)

    # Entry outside the 90-day window — must be ignored.
    create_transaction(account: account, amount: -10_000, date: 200.days.ago.to_date)

    assert_equal 300, goal.pace.to_d
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
    # After removing the only connected account, the goal is manual-only;
    # the copy must flip to "pledge_just_saved" so users aren't told to
    # wait for a sync that won't run. Refetch to exercise the real
    # request lifecycle rather than poking a memo on the same instance.
    reloaded = Goal.find(@goal.id)
    assert_equal "goals.show.pledge_just_saved", reloaded.pledge_action_label_key
  end

  test "explicit allocation backs only the earmarked slice" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Split Savings", currency: "USD", balance: 5_000)
    goal = @family.goals.create!(name: "Earmarked", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end
    assert_equal BigDecimal("1000"), goal.current_balance.to_d
  end

  test "explicit allocation is capped at the account balance via the haircut" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Over Earmark", currency: "USD", balance: 800)
    goal = @family.goals.create!(name: "Over", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 5_000)
    end
    assert_equal BigDecimal("800"), goal.current_balance.to_d
  end

  test "unallocated link claims the balance left after another goal's earmark" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Shared Savings", currency: "USD", balance: 5_000)
    earmarked = @family.goals.create!(name: "Earmarked", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 2_000)
    end
    whole = @family.goals.create!(name: "Whole", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account) # NULL = whole-balance remainder
    end
    assert_equal BigDecimal("2000"), earmarked.current_balance.to_d
    assert_equal BigDecimal("3000"), whole.current_balance.to_d
    # The two goals' shares of the shared account never exceed its balance.
    assert_equal account.balance.to_d, earmarked.current_balance.to_d + whole.current_balance.to_d
  end

  test "over-earmarked account scales fixed slices pro-rata" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Contested Savings", currency: "USD", balance: 5_000)
    a = @family.goals.create!(name: "Goal A", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 4_000)
    end
    b = @family.goals.create!(name: "Goal B", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 4_000)
    end
    # sum_fixed 8000 > balance 5000 -> each scaled by 5000/8000 -> 2500.
    assert_equal BigDecimal("2500"), a.current_balance.to_d
    assert_equal BigDecimal("2500"), b.current_balance.to_d
    assert_equal account.balance.to_d, a.current_balance.to_d + b.current_balance.to_d
  end

  test "archived goals release their earmark from the shared pool" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Release Savings", currency: "USD", balance: 5_000)
    whole = @family.goals.create!(name: "Whole", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    earmarked = @family.goals.create!(name: "Earmarked", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 2_000)
    end
    assert_equal BigDecimal("3000"), Goal.find(whole.id).current_balance.to_d
    earmarked.archive!
    # Archived goal no longer reserves its slice -> whole reclaims it.
    assert_equal BigDecimal("5000"), Goal.find(whole.id).current_balance.to_d
  end

  test "account free_to_earmark subtracts non-archived fixed earmarks" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Headroom Savings", currency: "USD", balance: 5_000)
    @family.goals.create!(name: "Earmarker", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_500)
    end
    assert_equal BigDecimal("1500"), account.goal_earmarked_total
    assert_equal BigDecimal("3500"), account.free_to_earmark
  end

  test "an overdrawn account backs nothing for fixed or whole-balance links" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Overdrawn", currency: "USD", balance: BigDecimal("-100"))
    fixed = @family.goals.create!(name: "Fixed OD", target_amount: 1_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 50)
    end
    whole = @family.goals.create!(name: "Whole OD", target_amount: 1_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    assert_equal 0.to_d, fixed.current_balance.to_d
    assert_equal 0.to_d, whole.current_balance.to_d
  end

  test "an archived goal still shows its own earmark, not the whole balance" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Archived Earmark", currency: "USD", balance: 5_000)
    earmarked = @family.goals.create!(name: "Archived Fixed", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 2_000)
    end
    earmarked.archive!
    # Excluded from the shared pool, but its own earmark is read from its own
    # goal_accounts — so it still reports 2,000, not the whole 5,000.
    assert_equal BigDecimal("2000"), Goal.find(earmarked.id).current_balance.to_d
  end

  test "earmark edits to an existing linked account persist via goal.save!" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Autosave Savings", currency: "USD", balance: 5_000)
    goal = @family.goals.create!(name: "Autosave goal", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account) # NULL = whole balance
    end
    ga = goal.goal_accounts.first
    assert_nil ga.allocated_amount
    ga.allocated_amount = 1_500
    goal.save! # autosave: true must persist the dirty existing child
    assert_equal BigDecimal("1500"), goal.goal_accounts.first.reload.allocated_amount
  end

  test "progress_percent memo resets after complete! on the same instance" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Memo Savings", currency: "USD", balance: 100)
    goal = @family.goals.create!(name: "Memo goal", target_amount: 1_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    assert_operator goal.progress_percent, :<, 100 # memoize the underfunded value
    goal.complete!
    assert_equal 100, goal.progress_percent, "stale memo would still report the pre-complete percent"
  end

  test "contributions basis excludes market gains" do
    account = Account.create!(family: @family, accountable: Investment.new, name: "Brokerage", currency: "USD", balance: 10_000)
    account.balances.create!(date: 10.days.ago.to_date, balance: 10_000, currency: "USD", net_market_flows: 3_000)
    goal = @family.goals.create!(name: "Invest goal", target_amount: 20_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    assert_equal "contributions", goal.progress_basis
    # 10,000 value − 3,000 market gain = 7,000 contributed.
    assert_equal BigDecimal("7000"), goal.current_balance.to_d
    assert_equal BigDecimal("10000"), goal.market_value_money.amount
  end

  test "reopen transitions a completed goal back to active" do
    fresh = goals(:emergency_fund)
    fresh.complete!
    assert fresh.completed?
    fresh.reopen!
    assert fresh.active?
  end

  test "investment accounts default to transfer pledge kind, never manual_save" do
    assert_equal "transfer", accounts(:investment).default_pledge_kind
  end

  test "adding an investment account via update flips a depository goal to contributions" do
    goal = goals(:emergency_fund)
    assert_equal "balance", goal.progress_basis
    goal.goal_accounts.build(account: accounts(:investment))
    goal.save!
    assert_equal "contributions", goal.reload.progress_basis
  end

  test "earmark is respected on a contributions-basis goal" do
    account = Account.create!(family: @family, accountable: Investment.new, name: "Brokerage2", currency: "USD", balance: 10_000)
    account.balances.create!(date: 5.days.ago.to_date, balance: 10_000, currency: "USD", net_market_flows: 2_000)
    goal = @family.goals.create!(name: "Earmarked invest", target_amount: 20_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end
    assert_equal "contributions", goal.progress_basis
    # net contributed = 10,000 − 2,000 = 8,000; earmark 1,000 ≤ 8,000 → 1,000.
    assert_equal BigDecimal("1000"), goal.current_balance.to_d
  end
end
