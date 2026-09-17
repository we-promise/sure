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

  # Two whole-account links on ONE account each claim the entire balance, so
  # the account is counted twice. The pro-rata haircut in backing_share_for
  # only scales FIXED earmarks: `others_fixed` sums allocated_amount, and an
  # unallocated link contributes nil.to_d == 0, so the two links never see
  # each other. GoalAccount now refuses to create this state (see
  # GoalAccountTest), but rows that predate the guard still read this way —
  # this test pins the behaviour those rows get, and is the reason the guard
  # exists.
  test "two grandfathered whole-account links each claim the full balance" do
    livret = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Livret A", currency: "USD", balance: 6_000
    )
    precaution = @family.goals.create!(
      name: "Precaution", target_amount: 5_000, currency: "USD",
      goal_accounts: [ GoalAccount.new(account: livret) ]
    )
    # Built with a fixed earmark so the new guard lets it through, then
    # forced to NULL behind the validation's back — exactly the shape of a
    # row written before the guard shipped.
    vacances = @family.goals.create!(
      name: "Vacances", target_amount: 5_000, currency: "USD",
      goal_accounts: [ GoalAccount.new(account: livret, allocated_amount: 1) ]
    )
    vacances.goal_accounts.first.update_column(:allocated_amount, nil)

    assert_equal 6_000, precaution.reload.current_balance.to_i
    assert_equal 6_000, vacances.reload.current_balance.to_i
    assert_equal 12_000, precaution.current_balance.to_i + vacances.current_balance.to_i,
                 "6 000 of balance backing 12 000 of goals — the double count B7 guards against"
    assert_equal 100, precaution.progress_percent.to_i
    assert_equal 100, vacances.progress_percent.to_i
  end

  # The confirm dialog assigns `body` to innerHTML, so an unescaped goal name
  # would execute when a family member opens the delete confirmation.
  test "deletion_confirm escapes the goal name in the dialog body" do
    @goal.name = "<img src=x onerror=alert(1)>"

    body = @goal.deletion_confirm.to_data_attribute[:body]

    assert_includes body, "&lt;img src=x onerror=alert(1)&gt;"
    assert_no_match(/<img/, body)
  end

  # Derived, not a hardcoded list: a locale added later ships a goals YAML
  # without these keys otherwise. `fallback: false` carries as much weight —
  # the backend has I18n::Backend::Fallbacks mixed in, so a missing German key
  # resolves to the English string and a plain `.present?` assertion passes
  # while a German family reads English in the dialog.
  test "confirm_delete copy resolves in every locale that ships goal translations" do
    locales = Rails.root.glob("config/locales/views/goals/*.yml").map { |f| f.basename(".yml").to_s.to_sym }
    assert_operator locales.size, :>=, 7, "goal locale files disappeared — check the glob"

    locales.each do |locale|
      body = I18n.t("goals.show.confirm_delete_body", name: "Wedding", locale: locale, fallback: false, default: nil)
      assert body, "#{locale} is missing goals.show.confirm_delete_body"
      assert_includes body, "Wedding", "#{locale} dropped the %{name} interpolation"

      %w[confirm_delete_title confirm_delete_cta].each do |key|
        assert I18n.t("goals.show.#{key}", locale: locale, fallback: false, default: nil).present?,
               "#{locale} is missing goals.show.#{key}"
      end
    end
  end

  # The days-left segment is returned separately so the view can keep it
  # unbroken; joined into one string it wrapped after "days" on a phone.
  test "header_summary_parts keeps the days-left phrase in its own segment" do
    # Pinned: the count is `target_date - Date.current`, so a suite that crossed
    # midnight between setting the date and reading it would report 183.
    travel_to Date.new(2026, 6, 1) do
      # Target well above the linked account's balance, or the goal reads as
      # :reached and drops the days-left segment on purpose.
      @goal.target_amount = 1_000_000
      @goal.target_date = Date.current + 184

      parts = @goal.header_summary_parts

      assert_equal 2, parts.size
      assert_match(/184 days left/, parts.last)
      assert_no_match(/days left/, parts.first)
    end
  end

  test "header_summary_parts omits days left once the target is reached" do
    @goal.target_date = 184.days.from_now.to_date
    @goal.complete!

    assert_equal 1, @goal.header_summary_parts.size
  end

  test "header_summary_parts is a single segment without a target date" do
    @goal.target_date = nil

    assert_equal 1, @goal.header_summary_parts.size
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

  # A whole-account link takes what is LEFT of the balance once other goals'
  # fixed earmarks are set aside — not the gross balance. This used to assert
  # the gross figure, which only held because the fixtures had three goals
  # claiming `depository` in full at once: the very state the exclusivity rule
  # forbids, and one where the same money was counted three times.
  test "current_balance sums linked account balances net of other goals' earmarks" do
    account_ids = @goal.linked_accounts.map(&:id)
    others_fixed = GoalAccount.where(account_id: account_ids)
                              .where.not(goal_id: @goal.id)
                              .sum(:allocated_amount)
    expected = @goal.linked_accounts.sum(&:balance).to_d - others_fixed

    assert_operator others_fixed, :>, 0, "fixtures should exercise the netting"
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

  # --- Lot B1: a reached goal lets go of its money ---

  # The whole scenario from the plan, as one regression test. Before B1 the
  # last line read 2500 / 50%: the completed goal kept reserving, the
  # untouched precaution goal was cut in half by the pro-rata haircut, and
  # archiving froze the wrong figure into the history.
  test "completing a goal frees its siblings and keeps its own history straight" do
    livret = Account.create!(family: @family, accountable: Depository.new, name: "Livret B1", currency: "USD", balance: 10_000)
    precaution = @family.goals.create!(name: "Precaution B1", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: livret, allocated_amount: 5_000)
    end
    vacances = @family.goals.create!(name: "Vacances B1", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: livret, allocated_amount: 5_000)
    end

    assert_equal BigDecimal("5000"), Goal.find(precaution.id).current_balance.to_d
    assert_equal BigDecimal("5000"), Goal.find(vacances.id).current_balance.to_d

    vacances.complete!
    livret.update!(balance: 5_000)

    assert_equal BigDecimal("5000"), Goal.find(precaution.id).current_balance.to_d,
                 "the untouched goal must keep its full earmark once its sibling is done"
    assert_equal 100, Goal.find(precaution.id).progress_percent.to_i
    assert_equal BigDecimal("5000"), Goal.find(vacances.id).current_balance.to_d,
                 "a completed goal reports what it reached, not what is left"

    vacances.archive!
    assert_equal BigDecimal("5000"), Goal.find(vacances.id).current_balance.to_d,
                 "archiving after completion must not rewrite the frozen figure"
  end

  test "a completed goal releases its earmark from the shared pool" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Pool Savings", currency: "USD", balance: 5_000)
    whole = @family.goals.create!(name: "Whole C", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    earmarked = @family.goals.create!(name: "Earmarked C", target_amount: 2_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 2_000)
    end

    assert_equal BigDecimal("3000"), Goal.find(whole.id).current_balance.to_d
    earmarked.complete!
    assert_equal BigDecimal("5000"), Goal.find(whole.id).current_balance.to_d
  end

  test "a completed goal keeps its amount when the balance later drops" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Spent Savings", currency: "USD", balance: 4_000)
    goal = @family.goals.create!(name: "Frozen", target_amount: 4_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    goal.complete!
    assert_equal BigDecimal("4000"), goal.completed_amount.to_d
    assert goal.completed_at.present?

    account.update!(balance: 100)
    assert_equal BigDecimal("4000"), Goal.find(goal.id).current_balance.to_d
  end

  # `archive` accepts a goal straight from active or paused, so an archived
  # goal that was never completed has no frozen amount — the read guard is
  # `completed_amount.present?`, not `completed?`.
  test "a goal archived without being completed keeps the live calculation" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Direct Archive", currency: "USD", balance: 3_000)
    goal = @family.goals.create!(name: "Straight to archive", target_amount: 3_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end

    goal.archive!
    assert_nil goal.completed_amount

    account.update!(balance: 250)
    assert_equal BigDecimal("250"), Goal.find(goal.id).current_balance.to_d
  end

  test "reopen and unarchive hand the goal back to the live calculation" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Thaw Savings", currency: "USD", balance: 2_000)

    [ :reopen, :unarchive ].each_with_index do |event, i|
      goal = @family.goals.create!(name: "Thaw #{i}", target_amount: 2_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: 1_000)
      end
      goal.complete!
      assert_equal BigDecimal("1000"), goal.completed_amount.to_d

      goal.archive! if event == :unarchive
      goal.public_send("#{event}!")

      assert_nil goal.reload.completed_amount, "#{event} must clear the frozen amount"
      assert_nil goal.completed_at
      account.update!(balance: 500)
      assert_equal BigDecimal("500"), Goal.find(goal.id).current_balance.to_d
      account.update!(balance: 2_000)
      goal.destroy!
    end
  end

  # Pause means "I have stopped feeding this", not "I have released it".
  test "a paused goal keeps reserving its earmark" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Paused Savings", currency: "USD", balance: 5_000)
    whole = @family.goals.create!(name: "Whole P", target_amount: 10_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account)
    end
    earmarked = @family.goals.create!(name: "Earmarked P", target_amount: 2_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 2_000)
    end

    earmarked.pause!
    assert_equal BigDecimal("3000"), Goal.find(whole.id).current_balance.to_d,
                 "a paused goal must keep its slice out of the pool's reach"
  end

  # free_to_earmark and the pool read the same set of goals — Goal::RELEASED_STATES.
  # If they disagreed, the account would advertise headroom the goals deny.
  test "free_to_earmark and the shared pool agree after a completion" do
    account = Account.create!(family: @family, accountable: Depository.new, name: "Agreement Savings", currency: "USD", balance: 5_000)
    goal = @family.goals.create!(name: "Agreeable", target_amount: 1_500, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_500)
    end

    assert_equal BigDecimal("1500"), account.goal_earmarked_total
    goal.complete!
    account.reload

    assert_equal BigDecimal("0"), account.goal_earmarked_total
    assert_equal BigDecimal("5000"), account.free_to_earmark
    assert_empty Goal.pooled_allocations_for(@family)[account.id].to_a
  end

  test "goals are one_off by default and kind is constrained" do
    assert @goal.one_off?
    assert_not @goal.maintained?

    @goal.kind = "nonsense"
    assert_not @goal.valid?
  end

  # --- Lot B3a: reserves to maintain ---

  test "a reserve is funded at its floor and depleted below it" do
    goal = reserve_goal(balance: 6_000, target: 6_000)
    assert_equal :funded, goal.status

    goal.linked_accounts.first.update!(balance: 4_500)
    assert_equal :depleted, Goal.find(goal.id).status
  end

  # `complete` releases the earmark. For a reserve that is the opposite of the
  # point, so the transition is refused outright rather than hidden in the UI.
  test "a reserve cannot be completed" do
    goal = reserve_goal(balance: 6_000, target: 6_000)

    assert_not goal.may_complete?
    assert_raises(AASM::InvalidTransition) { goal.complete! }
    assert_equal "active", goal.reload.state
    assert_nil goal.completed_amount
  end

  test "a one_off goal at its target can still be completed" do
    goal = reserve_goal(balance: 6_000, target: 6_000)
    goal.update!(kind: "one_off")

    assert goal.may_complete?
  end

  # monthly_target_amount and pace both derive from target_date, which a
  # reserve does not have — "save X/month to catch up" would be advice about
  # a deadline that does not exist.
  test "a depleted reserve is never behind pace" do
    goal = reserve_goal(balance: 1_000, target: 6_000)

    assert_equal :depleted, goal.status
    assert_not goal.behind_pace?
  end

  # ACTIVE_DISPLAY_STATUS_RANK falls back to 4 for anything unranked, so a
  # missing :depleted entry would sort a drained reserve dead last.
  # Named so the alphabetical tie-break works AGAINST the reserve: only the
  # rank can put it first. Unranked, :depleted would fall back to 4 and land
  # behind the open-ended goal's 2.
  test "a depleted reserve sorts ahead of a goal that needs nothing" do
    drained = reserve_goal(balance: 100, target: 6_000, name: "Zzz drained")
    open_ended = @family.goals.create!(
      name: "Aaa open ended", target_amount: 1_000, currency: "USD"
    ) do |g|
      g.goal_accounts.build(account: Account.create!(
        family: @family, accountable: Depository.new,
        name: "Open Ended Pot", currency: "USD", balance: 900
      ))
    end

    sorted = Goal.active_display_sort([ open_ended, drained ])

    assert_equal :depleted, drained.status
    assert_equal :no_target_date, open_ended.status
    assert_equal drained.id, sorted.first.id,
                 "a reserve below its floor must not sort below a goal that needs nothing"
  end

  # The reserve keeps reserving: a withdrawal creates a shortfall, it does not
  # release the earmark the way completing a one-off does.
  test "a withdrawal leaves a reserve's earmark in place" do
    goal = reserve_goal(balance: 6_000, target: 6_000, allocated: 6_000)
    account = goal.linked_accounts.first

    assert_equal BigDecimal("6000"), account.goal_earmarked_total

    account.update!(balance: 4_000)
    account.reload

    assert_equal BigDecimal("6000"), account.goal_earmarked_total,
                 "a reserve holds its earmark whatever the balance does"
    assert_equal :depleted, Goal.find(goal.id).status
    assert_equal BigDecimal("2000"), Goal.find(goal.id).remaining_amount.to_d
  end

  # --- Lot B3b: a floor expressed in months of expenses ---

  test "months mode is only for a reserve, and needs a number of months" do
    goal = reserve_goal(balance: 6_000, target: 6_000)

    goal.target_mode = "months_of_expenses"
    assert_not goal.valid?, "months mode without target_months must be refused"

    goal.target_months = 6
    assert goal.valid?, goal.errors.full_messages.to_sentence

    goal.kind = "one_off"
    assert_not goal.valid?, "a one-off goal has no months-of-expenses floor"
  end

  test "target_months without months mode is refused" do
    goal = reserve_goal(balance: 6_000, target: 6_000)
    goal.target_months = 6

    assert_not goal.valid?
  end

  # target_amount stays the source of truth — the aggregates that read it must
  # keep working with no knowledge of the mode.
  test "refreshing the floor moves every figure that reads target_amount" do
    goal = reserve_goal(balance: 3_000, target: 1_000)
    goal.update!(target_mode: "months_of_expenses", target_months: 6)
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))

    assert_equal BigDecimal("3000"), goal.refresh_target_from_expenses!

    refreshed = Goal.find(goal.id)
    assert_equal BigDecimal("3000"), refreshed.target_amount.to_d
    assert_equal :funded, refreshed.status
    assert_equal 100, refreshed.progress_percent
  end

  # A family with no spending history computes a floor of zero, which would
  # both break the target_amount > 0 constraint and read as "your reserve is
  # complete". The figure the user has been saving against stands.
  test "a zero median leaves the floor untouched" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))
    goal = reserve_goal(balance: 3_000, target: 1_000)
    goal.update!(target_mode: "months_of_expenses", target_months: 6)
    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d

    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))

    assert_nil goal.refresh_target_from_expenses!
    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d
  end

  # A reserve created in months mode must be right immediately: waiting for
  # the 1st would make the feature's first impression its least convincing.
  test "creating a months-mode reserve computes its floor straight away" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))
    account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Fresh Reserve Pot", currency: "USD", balance: 100
    )

    goal = @family.goals.create!(
      name: "Fresh reserve", target_amount: 1, currency: "USD",
      kind: "maintained", target_mode: "months_of_expenses", target_months: 6
    ) { |g| g.goal_accounts.build(account: account) }

    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d
  end

  test "changing the number of months recomputes the floor at once" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))
    goal = reserve_goal(balance: 100, target: 1)
    goal.update!(target_mode: "months_of_expenses", target_months: 6)
    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d

    goal.update!(target_months: 3)
    assert_equal BigDecimal("1500"), goal.reload.target_amount.to_d
  end

  # The monthly job owns the cadence: an unrelated edit must not quietly move
  # a financial figure the user has been saving against.
  test "renaming a months-mode reserve leaves its floor alone" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))
    goal = reserve_goal(balance: 100, target: 1)
    goal.update!(target_mode: "months_of_expenses", target_months: 6)

    IncomeStatement.any_instance.unstub(:median_expense)
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("900"))
    goal.update!(name: "Renamed reserve")

    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d,
                 "only the job, or a change of months, may move the floor"
  end

  test "a fixed reserve ignores the refresh entirely" do
    goal = reserve_goal(balance: 3_000, target: 1_000)
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))

    assert_nil goal.refresh_target_from_expenses!
    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  # The form asks this BEFORE the user has picked a kind or a number of months,
  # to decide whether to keep offering the amount field. So it must answer for
  # the family alone, not for what this goal happens to be right now.
  test "derivability is answered for the family, whatever the goal is set to" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))
    goal = reserve_goal(balance: 3_000, target: 1_000)

    assert goal.months_target_derivable?,
           "a one-off with no months set still has spending to derive from"
  end

  # With nothing to derive from, the typed amount is the only way to give the
  # reserve a target. The form has to be told, or it hides the only field that
  # would let the user do it.
  test "a family with no spending history can derive nothing" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))
    goal = reserve_goal(balance: 3_000, target: 1_000)

    assert_not goal.months_target_derivable?
  end

  test "derivability follows the goal's currency, not the family's" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("500"))
    goal = reserve_goal(balance: 3_000, target: 1_000)
    goal.stubs(:currency).returns("EUR")
    Money.any_instance.stubs(:exchange_to).raises(
      Money::ConversionError.new(from_currency: "USD", to_currency: "EUR", date: Date.current)
    )

    assert_not goal.months_target_derivable?,
               "no rate for the day means no figure to show, so the field must stay"
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

  test "behind_pace? excludes paused goals even when their raw status is behind" do
    goal = goals(:vacation_italy)
    goal.stubs(:status).returns(:behind)

    assert goal.behind_pace?

    goal.update!(state: "paused")

    assert goal.paused?
    assert_not goal.behind_pace?
  end

  test "summary_for counts behind goals via behind_pace? and sums one currency" do
    behind = goals(:vacation_italy)
    behind.stubs(:status).returns(:behind)
    paused_behind = goals(:emergency_fund)
    paused_behind.update!(state: "paused")
    paused_behind.stubs(:status).returns(:behind)

    summary = Goal.summary_for([ behind, paused_behind ], currency: "USD")

    assert_equal 1, summary[:behind_count]
    assert_kind_of Money, summary[:saved_money]
  end

  # --- Restoring a goal must not recreate a whole-account overlap ---
  #
  # The door-side tests — writing a link onto a contested account — live in
  # goal_account_test.rb. These cover the other way in: a state change, which
  # writes no link at all and so slips past that validation entirely.

  test "restoring an archived goal is refused when its account was claimed meanwhile" do
    account = standoff_account
    away = whole_account_goal("Away", account)
    away.archive!

    # Legitimate while `away` holds nothing: an archived goal releases its
    # accounts, so this claim is exactly what the pool expects.
    whole_account_goal("Claimer", account)

    away.reload
    assert_not away.unarchive!, "expected the restore to be refused"
    assert_equal "archived", away.reload.state
    assert_match "Claimer", away.errors.full_messages.to_sentence
  end

  test "restoring is allowed once the other goal earmarks a fixed slice instead" do
    account = standoff_account
    away = whole_account_goal("Away", account)
    away.archive!
    claimer = whole_account_goal("Claimer", account)

    claimer.goal_accounts.first.update!(allocated_amount: 2_000)

    away.reload
    assert away.unarchive!, away.errors.full_messages.to_sentence
    assert_equal "active", away.reload.state
  end

  test "restoring an archived goal whose account is still free is untouched" do
    account = standoff_account
    away = whole_account_goal("Away", account)
    away.archive!

    away.reload
    assert away.unarchive!, away.errors.full_messages.to_sentence
    assert_equal "active", away.reload.state
  end

  # `paused` is not a released state: a paused goal never let go of its
  # accounts, so nothing can legitimately have claimed one meanwhile. The guard
  # that restricts this check to restores from a released state is what keeps a
  # user holding a LEGACY overlap — data the rule predates — from being
  # stranded on a goal they merely shelved. Built through update_column, since
  # the overlap is exactly what the door now refuses to write.
  test "resuming a paused goal is never blocked, even on a legacy overlap" do
    account = standoff_account
    goal = whole_account_goal("Shelved", account)
    squatter = @family.goals.create!(name: "Squatter", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1)
    end
    squatter.goal_accounts.first.update_column(:allocated_amount, nil)

    goal.pause!

    assert goal.reload.resume!, goal.errors.full_messages.to_sentence
    assert_equal "active", goal.reload.state
  end

  # Once a goal is closed, `current_balance` returns the frozen amount and stops
  # tracking its accounts. Spending them afterwards used to send the projection
  # ratio past 1 — a frozen amount over a live 100 scaled every historical point
  # by the difference, drawing a chart that never happened.
  #
  # The series is stubbed at its collaborator rather than built from Balance
  # rows: ChartSeriesBuilder returns zeros for a fixture account here, and a
  # series of zeros multiplies to zero whatever the ratio, so the assertion
  # would pass without proving anything.
  test "the projection never scales the saved series past the accounts it came from" do
    goal = @family.goals.create!(name: "Closed trip", target_amount: 4_000, currency: "USD") do |g|
      g.goal_accounts.build(account: @depository, allocated_amount: 4_000)
    end
    goal.complete!
    @depository.update!(balance: 100)

    historical = OpenStruct.new(date: Date.current, value: Money.new(5_000, "USD"))
    Balance::ChartSeriesBuilder.any_instance
                               .stubs(:balance_series)
                               .returns(OpenStruct.new(values: [ historical ]))

    payload = Goal.find(goal.id).projection_payload

    # The series is the WHOLE linked-account history, scaled to this goal's
    # share of it. A share cannot exceed the whole, so no point may come out
    # above the historical figure it was scaled from — whatever the frozen
    # amount says. Unclamped this rendered 5,000 x 33.
    assert_not_empty payload[:saved_series], "empty series would make this assertion vacuous"
    assert_operator payload[:saved_series].first[:value].to_d, :<=, 5_000,
                    "a saved point outran the history it was scaled from"
  end


  # AASM runs an event's `after` hook on the non-bang form too, which does not
  # save. The completion snapshot used to be written there, so `complete` left
  # the row `active` in the database carrying a frozen amount and a completion
  # date — a goal still being funded that everything keying off
  # `completed_amount.present?` read as closed.
  test "complete without the bang stamps nothing" do
    goal = completable_goal

    goal.complete

    row = Goal.where(id: goal.id).pick(:state, :completed_amount, :completed_at)
    assert_equal "active", row[0]
    assert_nil row[1]
    assert_nil row[2]
  end

  test "complete! freezes the amount alongside the state it belongs to" do
    goal = completable_goal

    goal.complete!

    row = Goal.where(id: goal.id).pick(:state, :completed_amount, :completed_at)
    assert_equal "completed", row[0]
    assert_equal 4_000, row[1].to_d
    assert_not_nil row[2]
  end

  test "reopening without the bang thaws nothing" do
    goal = completable_goal
    goal.complete!

    goal.reopen

    assert_equal 4_000, Goal.where(id: goal.id).pick(:completed_amount).to_d
  end

  test "reopen! hands the goal back to the live calculation" do
    goal = completable_goal
    goal.complete!

    goal.reopen!

    assert_nil Goal.where(id: goal.id).pick(:completed_amount)
  end

  # --- Review follow-ups on the reserves lot ---

  test "a released goal cannot be turned into a reserve without reopening" do
    goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: standoff_account)
    end
    goal.complete!

    goal.reload.kind = "maintained"

    assert_not goal.valid?
    assert_includes goal.errors[:kind], "Reopen this goal before turning it into a reserve."
  end

  test "reopening first lets the conversion through" do
    goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: standoff_account)
    end
    goal.complete!
    goal.reload.reopen!

    assert goal.reload.update(kind: "maintained"), goal.errors.full_messages.to_sentence
  end

  # The form hides the date for a reserve, so one can only arrive through a
  # conversion or a crafted request. Either way it must not survive: a stored
  # deadline would drive a pace the reserve does not have.
  test "a reserve drops any target date it is given" do
    goal = reserve_goal(balance: 3_000, target: 6_000)

    assert goal.update(target_date: 6.months.from_now.to_date), goal.errors.full_messages.to_sentence
    assert_nil goal.reload.target_date
  end

  test "converting a dated goal into a reserve clears its deadline" do
    goal = @family.goals.create!(
      name: "Trip", target_amount: 5_000, currency: "USD", target_date: 6.months.from_now.to_date
    ) { |g| g.goal_accounts.build(account: standoff_account) }

    goal.update!(kind: "maintained")

    assert_nil goal.reload.target_date
  end

  test "a drained reserve gets a status callout telling it what is missing" do
    goal = reserve_goal(balance: 4_000, target: 6_000)

    assert_equal :depleted, goal.status
    assert_includes goal.status_callout_context.to_s, "2,000"
  end

  test "a reserve at its level has no callout to make" do
    goal = reserve_goal(balance: 6_000, target: 6_000)

    assert_equal :funded, goal.status
    assert_nil goal.status_callout_context
  end

  # Setting state and kind in one write skips the `reopen` transition, so
  # `completed_amount` never thaws. Reading the in-memory state let that
  # through: the goal looked already-reopened while its frozen snapshot
  # survived, and an active reserve reported it forever.
  test "reopening and converting in a single write is refused" do
    goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: standoff_account)
    end
    goal.complete!
    frozen = goal.reload.completed_amount

    assert_not goal.update(state: "active", kind: "maintained")
    assert_includes goal.errors[:kind], "Reopen this goal before turning it into a reserve."
    assert_equal "completed", goal.reload.state
    assert_equal frozen, goal.reload.completed_amount
  end


  # A reserve holds a level: there is no finish line to project toward and no
  # target to have "hit". It does not reach the projection panel today, but
  # this method reads as the single source of truth for that subtitle.
  test "a reserve is never told it has hit a target" do
    reserve = @family.goals.create!(
      name: "Precaution", target_amount: 1_000, currency: @family.currency, kind: "maintained"
    ) { |g| g.goal_accounts.build(account: attention_pot(1_000), allocated_amount: 1_000) }

    assert_equal :funded, reserve.status
    assert_equal I18n.t("goals.show.projection.reserve"), reserve.projection_summary
  end

  # `needs_attention?` names the pair once. Three places were spelling it out
  # and the Plan card had already fallen behind, leaving a depleted reserve
  # with an amber pill beside a neutral progress bar.
  test "a depleted reserve wants attention just as a goal off its pace does" do
    reserve = @family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: @family.currency, kind: "maintained"
    ) { |g| g.goal_accounts.build(account: attention_pot(1_000), allocated_amount: 1_000) }

    assert_equal :depleted, reserve.status
    assert reserve.needs_attention?
  end

  test "a funded reserve wants nothing" do
    reserve = @family.goals.create!(
      name: "Precaution", target_amount: 1_000, currency: @family.currency, kind: "maintained"
    ) { |g| g.goal_accounts.build(account: attention_pot(1_000), allocated_amount: 1_000) }

    assert_not reserve.needs_attention?
  end

  # --- months-of-expenses review follow-ups ---

  # The median comes back in FAMILY currency; target_amount is stored in the
  # GOAL's. A EUR reserve in a USD family would otherwise read a 3,000 dollar
  # floor as 3,000 euros, and rewrite it that way every month.
  test "a reserve in another currency gets its floor converted" do
    account = Account.create!(family: @family, accountable: Depository.new,
                              name: "EUR pot", currency: "EUR", balance: 1_000)
    goal = @family.goals.create!(
      name: "Precaution", target_amount: 1_000, currency: "EUR",
      kind: "maintained", target_mode: "months_of_expenses", target_months: 6
    ) { |g| g.goal_accounts.build(account: account, allocated_amount: 1_000) }

    # 500/month family currency x 6 months = 3,000, at a rate of 0.9 = 2,700.
    IncomeStatement.any_instance.stubs(:median_expense).returns(500)
    Money.any_instance.stubs(:exchange_to).returns(Money.new(2_700, "EUR"))

    goal.update!(target_amount: 1)

    assert_equal 2_700, goal.reload.target_amount.to_d
  end

  # The floor is derived in this mode. Without this the edit form could
  # persist an arbitrary figure under a "six months of expenses" label until
  # the next monthly refresh.
  test "a typed amount cannot stand in for a derived floor" do
    goal = months_based_reserve
    IncomeStatement.any_instance.stubs(:median_expense).returns(500)

    goal.update!(target_amount: 99)

    assert_equal 3_000, goal.reload.target_amount.to_d
  end

  # Nothing to derive from and a typed figure on its way in: a stale floor
  # beats a wrong one wearing a computed label.
  test "with no spending history a typed amount does not replace the floor" do
    goal = months_based_reserve
    IncomeStatement.any_instance.stubs(:median_expense).returns(0)

    goal.update!(target_amount: 99)

    assert_equal 3_000, goal.reload.target_amount.to_d
  end


  # The ring is drawn from `progress_percent`, which counts money held plus
  # money already spent on the goal. The headline figure showed only the first
  # half, so a goal that had spent part of its savings sat at a 100% ring
  # beside "3,000 of 5,000" — the two disagreeing on the same card, with
  # nothing to say which one to believe.
  test "the headline figure agrees with the ring after a spend" do
    goal = spent_goal

    assert_equal 100, goal.progress_percent
    assert_equal 5_000, goal.progress_amount_money.amount.to_d,
      "the figure beside the ring still reported the account balance"
  end

  # The amount is part of the total above it, never a second figure beside it:
  # a reader should have nothing to add up.
  test "what was used is reported as part of the total, and only when there is some" do
    goal = spent_goal

    assert goal.any_consumption?
    assert_equal 2_000, goal.consumed_amount_money.amount.to_d
    assert_equal goal.progress_amount_money.amount.to_d,
                 goal.current_balance.to_d + goal.consumed_amount_money.amount.to_d
  end

  test "a goal that has spent nothing says nothing about it" do
    account = Account.create!(family: @family, accountable: Depository.new,
                              name: "Quiet pot", currency: @family.currency, balance: 1_000)
    goal = @family.goals.create!(name: "Quiet", target_amount: 1_000, currency: @family.currency) do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end

    assert_not goal.any_consumption?
  end

  private

    # 5,000 saved, 2,000 of it since spent on the thing itself.
    def spent_goal
      account = Account.create!(family: @family, accountable: Depository.new,
                                name: "Spent pot #{SecureRandom.hex(3)}",
                                currency: @family.currency, balance: 5_000)
      goal = @family.goals.create!(name: "Trip", target_amount: 5_000, currency: @family.currency) do |g|
        g.goal_accounts.build(account: account, allocated_amount: 5_000)
      end
      goal.consume!(2_000)
      goal
    end

    # Its own account, so the shared-pool haircut does not make the frozen
    # figure depend on what the fixtures happen to claim.
    def completable_goal
      account = Account.create!(family: @family, accountable: Depository.new,
                                name: "Close pot #{SecureRandom.hex(3)}",
                                currency: @family.currency, balance: 4_000)
      @family.goals.create!(name: "Trip", target_amount: 4_000, currency: @family.currency) do |g|
        g.goal_accounts.build(account: account, allocated_amount: 4_000)
      end
    end

    def attention_pot(balance)
      Account.create!(family: @family, accountable: Depository.new,
                      name: "Pot #{SecureRandom.hex(3)}",
                      currency: @family.currency, balance: balance)
  end

    def months_based_reserve
      account = Account.create!(family: @family, accountable: Depository.new,
                                name: "Reserve pot #{SecureRandom.hex(3)}",
                                currency: @family.currency, balance: 3_000)
      IncomeStatement.any_instance.stubs(:median_expense).returns(500)
      @family.goals.create!(
        name: "Precaution", target_amount: 3_000, currency: @family.currency,
        kind: "maintained", target_mode: "months_of_expenses", target_months: 6
      ) { |g| g.goal_accounts.build(account: account, allocated_amount: 3_000) }
    end
    # A fresh account: the fixtures deliberately carry three goals holding
    # whole-account links on `depository`, a legacy overlap the exclusivity
    # rule tolerates but which would muddy every assertion here.
    def standoff_account
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "Standoff Savings #{SecureRandom.hex(4)}", currency: "USD", balance: 6_000
      )
    end

    def whole_account_goal(name, account)
      @family.goals.create!(name: name, target_amount: 5_000, currency: "USD") do |goal|
        goal.goal_accounts.build(account: account)
      end
    end

    def reserve_goal(balance:, target:, allocated: nil, name: "Emergency reserve")
      account = Account.create!(
        family: @family, accountable: Depository.new,
        name: "#{name} Pot", currency: "USD", balance: balance
      )
      @family.goals.create!(name: name, target_amount: target, currency: "USD", kind: "maintained") do |g|
        g.goal_accounts.build(account: account, allocated_amount: allocated)
      end
    end

    # :funded and paused both used to rank 3, so a paused goal whose name sorted
    # first jumped ahead of a reserve that was whole.
    test "a paused goal sorts behind a funded reserve whatever its name" do
      pot = ->(name) {
        Account.create!(family: @family, accountable: Depository.new, name: name,
                        currency: @family.currency, balance: 2_000)
      }
      reserve = @family.goals.create!(
        name: "Zeta reserve", target_amount: 1_000, currency: @family.currency, kind: "maintained"
      ) { |g| g.goal_accounts.build(account: pot.call("Zeta pot"), allocated_amount: 1_000) }
      paused = @family.goals.create!(
        name: "Alpha goal", target_amount: 1_000, currency: @family.currency
      ) { |g| g.goal_accounts.build(account: pot.call("Alpha pot"), allocated_amount: 1_000) }
      paused.pause!

      sorted = Goal.active_display_sort([ paused, reserve ])

      assert_equal [ reserve.id, paused.id ], sorted.map(&:id)
    end
end
