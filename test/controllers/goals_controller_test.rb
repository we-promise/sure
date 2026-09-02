require "test_helper"

class GoalsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @goal = goals(:vacation_italy)
    @depository = accounts(:depository)
    @connected = accounts(:connected)
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get goals_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "index renders with active filter by default" do
    get goals_url
    assert_response :success
    assert_match(/Goals/i, response.body)
  end

  test "index honors state filter" do
    get goals_url(state: "paused")
    assert_response :success
  end

  test "show renders the goal" do
    get goal_url(@goal)
    assert_response :success
    assert_match(@goal.name, response.body)
  end

  test "new renders the modal form" do
    get new_goal_url
    assert_response :success
  end

  test "create persists a goal with linked accounts" do
    # Fresh accounts: the goal fixtures already claim @depository and
    # @connected in full, and GoalAccount refuses a second whole-balance
    # link on a contested account. Blank allocations here keep this test on
    # the default "dedicate the whole balance" path.
    first = unclaimed_account("Holiday Pot")
    second = unclaimed_account("House Pot")

    assert_difference -> { Goal.count } => 1,
                      -> { GoalAccount.count } => 2 do
      post goals_url, params: {
        goal: {
          name: "New goal",
          target_amount: "1000",
          target_date: 3.months.from_now.to_date.iso8601,
          color: "#4da568",
          account_ids: [ first.id, second.id ]
        }
      }
    end

    goal = Goal.order(created_at: :desc).first
    assert_redirected_to goal_path(goal)
  end

  test "create rejects missing account_ids" do
    assert_no_difference "Goal.count" do
      post goals_url, params: {
        goal: {
          name: "Bad goal",
          target_amount: "1000",
          color: "#4da568"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create rejects foreign accounts" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)

    assert_no_difference "Goal.count" do
      post goals_url, params: {
        goal: {
          name: "Foreign goal",
          target_amount: "1000",
          color: "#4da568",
          account_ids: [ foreign.id ]
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "new form excludes same-family accounts not shared with the current user" do
    # Regression for #2168: funding-account picker leaked accounts owned by
    # other family members that were never shared with the current user.
    private_account = Account.create!(
      family: @user.family,
      owner: users(:family_member),
      accountable: Depository.new,
      name: "Member Private Checking",
      currency: "USD",
      balance: 100
    )

    get new_goal_url
    assert_response :success
    assert_no_match(/Member Private Checking/, response.body)
    assert_no_match(/goal_account_ids_#{private_account.id}/, response.body)
  end

  # A goal can be backed by an account the viewer is not allowed to see. Both
  # halves of that leak matter: the dialog naming it, and a direct POST moving
  # its earmark — the figures afterwards saying how much was in it.
  test "the consumption dialog does not name a linked account the viewer cannot see" do
    private_account = private_linked_account

    get consume_goal_url(@goal)

    assert_response :success
    assert_no_match(/Member Private Checking/, response.body)
    assert_no_match(/#{private_account.id}/, response.body)
  end

  test "consumption is refused against a linked account the viewer cannot see" do
    private_account = private_linked_account
    link = @goal.goal_accounts.find_by(account_id: private_account.id)

    post consume_goal_url(@goal), params: { amount: "100", account_id: private_account.id }

    assert_redirected_to goal_path(@goal)
    assert_equal 0, @goal.reload.consumed_amount
    assert_equal 500, link.reload.allocated_amount
  end

  # The outflow panel is the third door onto a private backing account: it
  # would list its transactions, naming the account, its spending and roughly
  # its size to someone with no access to it.
  test "the outflow panel does not surface a spend on an account the viewer cannot see" do
    private_account = private_linked_account
    private_account.entries.create!(
      name: "Private Spend", date: Date.current, amount: 400,
      currency: private_account.currency, entryable: Transaction.new
    )

    get goal_url(@goal)

    assert_response :success
    assert_no_match(/Private Spend/, response.body)
  end

  test "create rejects a same-family account not shared with the current user" do
    private_account = Account.create!(
      family: @user.family,
      owner: users(:family_member),
      accountable: Depository.new,
      name: "Member Private Checking",
      currency: "USD",
      balance: 100
    )

    assert_no_difference "Goal.count" do
      post goals_url, params: {
        goal: {
          name: "Sneaky goal",
          target_amount: "1000",
          color: "#4da568",
          account_ids: [ private_account.id ]
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "update modifies identity fields" do
    patch goal_url(@goal), params: { goal: { name: "Renamed" } }
    assert_redirected_to goal_path(@goal)
    assert_equal "Renamed", @goal.reload.name
  end

  test "update without account_ids leaves linked accounts intact" do
    before = @goal.goal_accounts.pluck(:account_id).sort
    patch goal_url(@goal), params: { goal: { name: "Still here" } }
    assert_redirected_to goal_path(@goal)
    assert_equal before, @goal.reload.goal_accounts.pluck(:account_id).sort
  end

  test "update with account_ids syncs linked accounts (add + remove)" do
    patch goal_url(@goal), params: { goal: { account_ids: [ @connected.id ] } }
    assert_redirected_to goal_path(@goal)
    assert_equal [ @connected.id ], @goal.reload.goal_accounts.pluck(:account_id)
  end

  test "update preserves a linked account the current user cannot access" do
    # Regression for #2172 review: a family goal can be linked to a private
    # account owned by another member. That account is never rendered in the
    # picker, so its absence from the submitted set must not unlink it.
    private_account = Account.create!(
      family: @user.family,
      owner: users(:family_member),
      accountable: Depository.new,
      name: "Member Private Checking",
      currency: @goal.currency,
      balance: 100
    )
    @goal.goal_accounts.create!(account: private_account)

    patch goal_url(@goal), params: { goal: { account_ids: [ @depository.id ] } }

    assert_redirected_to goal_path(@goal)
    linked = @goal.reload.goal_accounts.pluck(:account_id)
    assert_includes linked, private_account.id, "inaccessible private link must be preserved"
    assert_includes linked, @depository.id
  end

  test "update with empty account_ids re-renders with error" do
    patch goal_url(@goal), params: { goal: { account_ids: [ "" ] } }
    assert_response :unprocessable_entity
    assert_not_empty @goal.reload.goal_accounts
  end

  test "update rejects a cross-currency account attachment" do
    # Regression: sync_linked_accounts! used to call goal_accounts.create!
    # directly, bypassing Goal#linked_accounts_must_match_goal_currency.
    eur_account = Account.create!(
      family: @goal.family,
      accountable: Depository.new,
      name: "EUR Checking",
      currency: "EUR",
      balance: 100
    )
    before_ids = @goal.goal_accounts.pluck(:account_id).sort

    patch goal_url(@goal), params: { goal: { account_ids: [ eur_account.id ] } }

    assert_response :unprocessable_entity
    assert_equal before_ids, @goal.reload.goal_accounts.pluck(:account_id).sort
  end

  test "pause/resume/complete/archive/unarchive flow" do
    fresh = goals(:emergency_fund)
    patch pause_goal_url(fresh)
    assert fresh.reload.paused?
    patch resume_goal_url(fresh)
    assert fresh.reload.active?
    patch complete_goal_url(fresh)
    assert fresh.reload.completed?
    patch archive_goal_url(fresh)
    assert fresh.reload.archived?
    patch unarchive_goal_url(fresh)
    assert fresh.reload.active?
  end

  # The reported bug: Delete rendered only when the goal was archived, so an
  # active goal had no delete affordance anywhere in the UI. The kebab is the
  # only route to it, so assert the form is actually in the markup per state —
  # a 200 alone would not have caught the original miss.
  test "show exposes delete for a goal in every state" do
    delete_form = "form[action='#{goal_path(@goal)}'] input[name='_method'][value='delete']"

    %w[active paused completed archived].each do |state|
      @goal.update_column(:state, state)

      get goal_url(@goal)

      assert_response :success
      assert_select delete_form, 1, "no delete affordance on a #{state} goal"
    end
  end

  # A goal whose last funding account is deleted survives with zero links and
  # fails `must_have_at_least_one_linked_account` from then on. Editing is the
  # only way back, so update must validate the accounts the user SUBMITTED,
  # not the stale (empty) set already on the record.
  test "an orphaned goal can be repaired by re-linking an account" do
    orphan = orphaned_goal
    rescue_account = unclaimed_account("Rescue Pot")

    patch goal_url(orphan), params: {
      goal: { name: orphan.name, target_amount: orphan.target_amount, account_ids: [ rescue_account.id ] }
    }

    assert_redirected_to goal_path(orphan)
    assert_equal [ rescue_account.id ], orphan.reload.goal_accounts.pluck(:account_id)
    assert orphan.valid?
  end

  # AASM's bang event returns false rather than raising when the post-transition
  # save fails validation. The controller used to discard that, flashing
  # "Goal archived." while the state never moved.
  test "a transition that fails validation reports the error, not success" do
    orphan = orphaned_goal

    patch archive_goal_url(orphan)

    assert_redirected_to goal_path(orphan)
    assert_nil flash[:notice]
    assert_match(/at least one account/i, flash[:alert])
    assert_equal "active", orphan.reload.state
  end

  test "destroy deletes an active goal and cascades to its links and pledges" do
    assert_difference -> { Goal.count } => -1,
                      -> { GoalAccount.count } => -2,
                      -> { GoalPledge.count } => -2 do
      delete goal_url(@goal)
    end
    assert_redirected_to goals_path
  end

  test "destroy deletes an archived goal" do
    @goal.archive!
    assert_difference "Goal.count", -1 do
      delete goal_url(@goal)
    end
    assert_redirected_to goals_path
  end

  # The one thing a goal delete reaches outside its own tables: a matched
  # pledge stamps `extra["goal"]["pledge_id"]` onto the transaction it claimed,
  # and GoalPledge#clear_matched_transaction_extra must unstamp it on the way
  # out. The transaction itself must survive untouched.
  test "destroy unstamps the transaction a matched pledge claimed" do
    txn = create_transaction(account: @connected, amount: -300).entryable
    pledge = goal_pledges(:matched_transfer)
    txn.update!(extra: { "goal" => { "pledge_id" => pledge.id } })
    pledge.update_column(:matched_transaction_id, txn.id)

    delete goal_url(@goal)

    assert_redirected_to goals_path
    assert Transaction.exists?(txn.id), "deleting a goal must not delete the transaction"
    assert_nil txn.reload.extra.dig("goal", "pledge_id")
  end

  test "index KPI swaps to 'All caught up' when every tracked goal is reached" do
    family = users(:family_admin).family
    family.goals.destroy_all
    # Real reached state: target $1 against the depository fixture's
    # $5000 balance. Stubbing :status hides whether the controller
    # actually reads the right method on each goal.
    build_goal(family, "Wedding", target_amount: 1, target_date: 1.year.from_now)

    get goals_url
    assert_response :success
    assert_match(/All caught up/i, response.body)
    assert_match(/1\s*reached/i, response.body)
  end

  test "index KPI 'on track' denominator excludes no-target-date goals" do
    family = users(:family_admin).family
    family.goals.destroy_all
    # One trackable goal (has target_date) + one open-ended (no target_date).
    # The trackable one should be the only thing in the denominator;
    # open-ended goals can't be off pace because they have no required pace.
    build_goal(family, "House", target_amount: 1_000_000, target_date: 1.year.from_now)
    build_goal(family, "Emergency", target_amount: 1_000_000, target_date: nil)

    get goals_url
    assert_response :success
    # Expect "0 of 1" — the open-ended goal stays out of the fraction
    # even though it's active.
    assert_match(/0\s*of\s*1/i, response.body)
    assert_match(/without a deadline/i, response.body)
  end

  # The form reads its ticks from a separate local, not from the built links,
  # so a failed create rendered every account unchecked while the amounts the
  # user typed survived — an error telling them to enter an amount, on a form
  # whose accounts had silently cleared.
  test "a rejected creation keeps the accounts the user ticked" do
    account = Account.create!(
      family: @user.family, accountable: Depository.new,
      name: "Contested Pot", currency: @user.family.currency, balance: 3_000
    )
    holder = @user.family.goals.create!(name: "Holder", target_amount: 5_000, currency: @user.family.currency) do |g|
      g.goal_accounts.build(account: account)
    end
    assert holder.persisted?

    post goals_url, params: {
      goal: {
        name: "Second claim", target_amount: 5_000,
        account_ids: [ account.id ], allocations: { account.id.to_s => "" }
      }
    }

    assert_response :unprocessable_entity
    assert_select "input[type=checkbox][name='goal[account_ids][]'][value=?][checked]", account.id
  end

  # --- Lot B2: closing a reached goal ---

  # The panel used to say "Goal closed at ..." for a goal that was merely at
  # 100%, and offer Archive — the gesture that does NOT release the money.
  test "a one_off goal at 100 percent is offered closing, not archiving" do
    goal = fully_funded_goal

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.celebration.close_cta"), response.body
    assert_match I18n.t("goals.show.celebration.close_hint"), response.body
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.archive_cta"))}/, response.body)
  end

  test "a goal below 100 percent is offered no closing action" do
    goal = fully_funded_goal
    goal.update!(target_amount: 10_000)

    get goal_url(goal)

    assert_response :success
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.close_cta"))}/, response.body)
  end

  # Reaching the target is the normal state of a reserve, not a prompt to
  # close it — and B3 forbids `complete` for them outright.
  test "a maintained goal at 100 percent is never offered closing" do
    goal = fully_funded_goal
    goal.update_column(:kind, "maintained")

    get goal_url(goal)

    assert_response :success
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.close_cta"))}/, response.body)
  end

  test "a completed goal shows the amount and date it froze" do
    goal = fully_funded_goal
    goal.complete!

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.celebration.frozen",
                        date: I18n.l(goal.reload.completed_at.to_date, format: :long),
                        amount: goal.current_balance_money.format(precision: 0)),
                 response.body
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.close_cta"))}/, response.body)
  end

  test "an archived goal is offered no closing action" do
    goal = fully_funded_goal
    goal.archive!

    get goal_url(goal)

    assert_response :success
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.close_cta"))}/, response.body)
  end


  # --- Lot B3a: reserves ---

  test "create accepts the maintained kind" do
    account = unclaimed_account("Reserve Pot")

    assert_difference -> { Goal.count }, 1 do
      post goals_url, params: {
        goal: { name: "Emergency", target_amount: "6000", color: "#4da568", kind: "maintained", account_ids: [ account.id ] }
      }
    end

    assert Goal.order(created_at: :desc).first.maintained?
  end

  # The AASM guard refuses the transition; the controller must report that
  # rather than claim success or blow up.
  test "completing a reserve is refused at the controller too" do
    goal = fully_funded_goal
    goal.update_column(:kind, "maintained")

    patch complete_goal_url(goal)

    assert_redirected_to goal_path(goal)
    assert_match(/./, flash[:alert].to_s)
    assert_equal "active", goal.reload.state
  end

  test "a funded reserve reads as intact, with nothing to do" do
    goal = fully_funded_goal
    goal.update_column(:kind, "maintained")

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.celebration.heading_reserve"), response.body
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.close_cta"))}/, response.body)
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.celebration.archive_cta"))}/, response.body)
  end

  # A reserve has no deadline and no pace benchmark, so it can never land in
  # the on-track numerator. Leaving it in the denominator made a family with
  # one reserve read "0 of 1 on track" for a goal working exactly as intended.
  test "a reserve stays out of the on-track denominator" do
    @user.family.goals.where.not(state: "archived").find_each(&:archive!)
    account = Account.create!(
      family: @user.family, accountable: Depository.new,
      name: "Reserve Pot", currency: @user.family.currency, balance: 1_000
    )
    @user.family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: @user.family.currency, kind: "maintained"
    ) { |g| g.goal_accounts.build(account: account) }

    get goals_url

    assert_response :success
    # The tile prints "<on track> of <tracked total>". The reserve must not
    # appear in the denominator: before this, the page read "0 of 1".
    assert_no_match(/0 of 1/, response.body)
    assert_match(/0 of 0/, response.body)
  end

  # A brand-new reserve is depleted with a zero balance, which used to match the
  # generic "make your first transfer" branch first. It is still a reserve short
  # of its floor, and the shortfall panel is what says so.
  test "a reserve with nothing in it yet gets the shortfall panel" do
    account = Account.create!(
      family: @user.family, accountable: Depository.new,
      name: "Empty Reserve Pot", currency: @user.family.currency, balance: 0
    )
    goal = @user.family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: @user.family.currency, kind: "maintained"
    ) { |g| g.goal_accounts.build(account: account) }

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.show.reserve_shortfall.heading"), response.body
    assert_no_match(/#{Regexp.escape(I18n.t("goals.show.empty.heading"))}/, response.body)
  end

  # --- Lot B6: earmark headroom in the form ---

  test "the new form renders each account's balance and what other goals hold" do
    account = unclaimed_account("Headroom Pot")
    @user.family.goals.create!(name: "Neighbour", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 400)
    end

    get new_goal_url

    assert_response :success
    assert_select "[data-balance][data-earmarked-by-others]", minimum: 1
    assert_match 'data-earmarked-by-others="400.0"', response.body
  end

  # The N+1 this lot exists to avoid: the form lists every fundable account,
  # so reading the pool per account would scale with the account list.
  test "the form reads the shared pool exactly once, however many accounts" do
    3.times { |i| unclaimed_account("Pool Pot #{i}") }

    assert_equal 1, count_pool_queries { get new_goal_url }
    assert_response :success
  end

  # The acceptance criterion of this lot: reopening a goal must not count its
  # own earmark, or re-entering the same figure would trip a message about a
  # setup the user has not touched.
  test "the edit form does not count the edited goal's own earmark" do
    account = unclaimed_account("Reopen Pot")
    goal = @user.family.goals.create!(name: "Reopened", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 5_000)
    end

    get edit_goal_url(goal)

    assert_response :success
    assert_match 'data-earmarked-by-others="0.0"', response.body
    assert_no_match(/data-earmarked-by-others="5000/, response.body)
  end

  # The error paths re-render the same form, so they need the pool too —
  # without it the row helper is handed nil and the render blows up.
  test "the pool is available again when create re-renders after an error" do
    unclaimed_account("Error Pot")

    post goals_url, params: { goal: { name: "No accounts", target_amount: "1000", color: "#4da568" } }

    assert_response :unprocessable_entity
    assert_select "[data-balance][data-earmarked-by-others]", minimum: 1
  end

  # --- Lot B4: recording a partial spend ---

  test "recording a spend keeps the goal at full progress and frees the earmark" do
    account = Account.create!(
      family: @user.family, accountable: Depository.new,
      name: "Trip Pot", currency: @user.family.currency, balance: 5_000
    )
    goal = @user.family.goals.create!(name: "Trip", target_amount: 5_000, currency: @user.family.currency) do |g|
      g.goal_accounts.build(account: account, allocated_amount: 5_000)
    end

    post consume_goal_url(goal), params: { amount: 2_000 }

    assert_redirected_to goal_url(goal)
    assert_equal 2_000, goal.reload.consumed_amount
    assert_equal 3_000, goal.goal_accounts.first.reload.allocated_amount
  end

  test "a refused spend says which rule refused it" do
    account = Account.create!(
      family: @user.family, accountable: Depository.new,
      name: "Reserve Pot", currency: @user.family.currency, balance: 4_000
    )
    reserve = @user.family.goals.create!(
      name: "Precaution", target_amount: 6_000, currency: @user.family.currency, kind: "maintained"
    ) { |g| g.goal_accounts.build(account: account) }

    post consume_goal_url(reserve), params: { amount: 1_000 }

    assert_redirected_to goal_url(reserve)
    assert_equal I18n.t("goals.consume.errors.maintained"), flash[:alert]
    assert_equal 0, reserve.reload.consumed_amount
  end

  # A blank account id means "this goal has one link". An id resolving to
  # nothing must not fall back to that, or a single-link goal would record a
  # spend against an account the user never named.
  test "an unknown account id is refused rather than falling through" do
    account = Account.create!(
      family: @user.family, accountable: Depository.new,
      name: "Trip Pot", currency: @user.family.currency, balance: 5_000
    )
    goal = @user.family.goals.create!(name: "Trip", target_amount: 5_000, currency: @user.family.currency) do |g|
      g.goal_accounts.build(account: account, allocated_amount: 5_000)
    end

    post consume_goal_url(goal), params: { amount: 1_000, account_id: SecureRandom.uuid }

    assert_equal I18n.t("goals.consume.errors.account_not_linked"), flash[:alert]
    assert_equal 0, goal.reload.consumed_amount
  end

  # --- Lot B5: attributing an outflow the app spotted ---

  test "the goal page offers an outflow nothing has claimed" do
    goal, entry = goal_with_outflow

    get goal_url(goal)

    assert_response :success
    assert_match I18n.t("goals.unattributed_outflows.heading"), response.body
    assert_match entry.name, response.body
  end

  test "attributing an outflow takes its amount and stops offering it" do
    goal, entry = goal_with_outflow

    post consume_goal_url(goal), params: { transaction_id: entry.entryable_id }

    assert_redirected_to goal_url(goal)
    assert_equal entry.amount.to_d, goal.reload.consumed_amount

    get goal_url(goal)
    assert_no_match I18n.t("goals.unattributed_outflows.heading"), response.body
  end

  # The stamp is what makes this idempotent: replaying the same attribution
  # must not credit the goal twice for one spend.
  test "the same outflow cannot be attributed twice" do
    goal, entry = goal_with_outflow
    post consume_goal_url(goal), params: { transaction_id: entry.entryable_id }
    recorded = goal.reload.consumed_amount

    post consume_goal_url(goal), params: { transaction_id: entry.entryable_id }

    assert_equal recorded, goal.reload.consumed_amount
    assert_equal I18n.t("goals.consume.errors.transaction_not_found"), flash[:alert]
  end

  # The months mode could not be created from the UI at all. The form makes the
  # amount read-only, so it submits empty; `target_amount` is required and
  # validations run before any save callback, so the derivation that fills it
  # never ran. Every existing test set the amount explicitly, which is why the
  # model looked fine.
  test "a months-of-expenses reserve can be created without typing an amount" do
    account = unclaimed_account("Reserve Pot")
    IncomeStatement.any_instance.stubs(:median_expense).returns(500)

    assert_difference -> { Goal.count }, 1 do
      post goals_url, params: { goal: {
        name: "Precaution", color: "#4da568", kind: "maintained",
        target_mode: "months_of_expenses", target_months: "6",
        target_amount: "", account_ids: [ account.id ]
      } }
    end

    goal = Goal.order(created_at: :desc).first
    assert_equal 3_000, goal.target_amount.to_d, "the floor was not derived from the months"
    assert goal.maintained?
  end

  # A fixed reserve still needs one, and still says so. Asserted on the error the
  # form puts in front of the user, not on the status alone: a 422 for some
  # unrelated reason would otherwise keep this green while the guard it names
  # had quietly gone.
  test "a fixed-amount goal still requires the amount" do
    account = unclaimed_account("Fixed Pot")

    assert_no_difference -> { Goal.count } do
      post goals_url, params: { goal: {
        name: "No amount", color: "#4da568",
        target_amount: "", account_ids: [ account.id ]
      } }
    end

    assert_response :unprocessable_entity
    # The paragraph is in the markup either way; `hidden` is what decides
    # whether it is shown, so its absence is the assertion.
    assert_select "[data-goal-form-target=amountError]:not(.hidden)", 1,
      "the form did not surface the missing-amount error"
  end

  # The surface the user actually reads: the figure beside the ring, and the
  # line saying part of it has been used. Asserted on the rendered page rather
  # than the model, because the contradiction was a display bug — the model
  # has always counted both halves.
  test "the goal page reports the used portion as part of the total" do
    goal = spent_goal_for_display

    get goal_url(goal)

    assert_response :success
    assert_includes response.body, I18n.t("goals.show.ring.including_used",
                                          amount: goal.consumed_amount_money.format(precision: 0))

    # The headline figure specifically, not "somewhere on the page": the
    # account balance still appears in the funding breakdown below, which is
    # where that question belongs.
    headline = css_select("p.text-xl.font-medium.text-primary").map(&:text).map(&:strip)
    assert_includes headline, goal.progress_amount_money.format(precision: 0)
    assert_not_includes headline, goal.current_balance_money.format(precision: 0)
  end

  test "a goal that has spent nothing says nothing about it" do
    account = unclaimed_account("Quiet Pot")
    goal = @user.family.goals.create!(name: "Quiet", target_amount: 1_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end

    get goal_url(goal)

    assert_response :success
    assert_no_match(/already used|déjà utilisés/, response.body)
  end


  # The ring announced the account balance while the visible headline beside it
  # reported the progress total: same ring, two different numbers depending on
  # whether you could see it.
  test "the ring announces the same total the headline shows" do
    goal = spent_goal_for_display

    get goal_url(goal)

    assert_response :success
    label = css_select("[role=progressbar]").first["aria-label"]
    assert_includes label, goal.progress_amount_money.format
    assert_not_includes label, goal.current_balance_money.format
    assert_includes label, goal.consumed_amount_money.format
  end

  test "a goal with nothing used keeps the plain wording" do
    account = unclaimed_account("Plain Pot")
    goal = @user.family.goals.create!(name: "Plain", target_amount: 1_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end

    get goal_url(goal)

    label = css_select("[role=progressbar]").first["aria-label"]
    assert_no_match(/already used|déjà utilisés/, label)
  end


  # A reserve holds a balance rather than reaching an amount. "Target balance"
  # is what this kind of app calls that, and it keeps the noun the rest of the
  # page already uses 55 times — rather than inventing a "level" or a "floor"
  # that nothing else in the domain says.
  test "the form carries both the amount and the balance wording" do
    unclaimed_account("Vocab Pot")

    get new_goal_url

    assert_response :success
    assert_includes response.body, I18n.t("goals.form.fields.target_amount")
    assert_includes response.body, I18n.t("goals.form.fields.target_balance")
  end

  # In months mode the balance is worked out, not typed. A read-only input
  # still reads as something to fill in, beside the months that are the real
  # question, so the figure is presented as a result instead.
  test "the form carries the derived balance as a result, not a field" do
    unclaimed_account("Derived Pot")

    get new_goal_url

    assert_response :success
    assert_select "[data-goal-kind-target=amountDerived]", 1
    assert_includes response.body, I18n.t("goals.form.fields.target_balance_pending")
  end

  test "editing a months reserve shows the balance it currently holds" do
    account = unclaimed_account("Existing Pot")
    IncomeStatement.any_instance.stubs(:median_expense).returns(500)
    goal = @user.family.goals.create!(
      name: "Precaution", target_amount: 3_000, currency: "USD", kind: "maintained",
      target_mode: "months_of_expenses", target_months: 6
    ) { |g| g.goal_accounts.build(account: account, allocated_amount: 3_000) }

    get edit_goal_url(goal)

    assert_response :success
    assert_includes response.body, goal.target_amount_money.format(precision: 0)
  end

  # One vocabulary, not three. "level" and "floor" said the same thing as
  # "target balance" in different words, on the same page.
  test "the goals copy settles on one word for a reserve's balance" do
    %i[en fr].each do |locale|
      copy = YAML.load_file(Rails.root.join("config/locales/views/goals/#{locale}.yml")).to_s
      assert_no_match(/\bfloor\b|\bniveau\b/i, copy, "#{locale} still mixes vocabularies")
    end
  end

  # The gap this closes: at the moment the user has reached the target and
  # spent some of it, the page offered only "Close this goal" — which releases
  # the earmark, and whose own hint says to do it once the money is actually
  # spent. Saying so was two clicks away in the overflow menu.
  test "a reached goal offers recording a spend outside the overflow menu" do
    goal = reached_goal_holding_money

    get goal_url(goal)

    assert_response :success
    # In the panel, not only in the menu: scoped to the celebration panel's own
    # action row by id. `section` was not enough — the panel renders through
    # DS::Card, which emits a <section>, so any card on the page satisfied it.
    panel_links = css_select("#goal-celebration-actions a[href='#{consume_goal_path(goal)}']")
    assert_operator panel_links.size, :>=, 1,
      "the spend action was still only reachable through the overflow menu"
  end

  test "closing is still offered alongside it" do
    goal = reached_goal_holding_money

    get goal_url(goal)

    assert_select "form[action=?]", complete_goal_path(goal)
  end

  # Two doors lead to the same dialog, the panel and the overflow menu, and they
  # disagreed: the menu gated on `current_balance`, which counts every linked
  # account including ones private to another member. A reader backed only by
  # such an account was shown the entry, opened a dialog with nothing to pick,
  # and was refused on submit. Asserted page-wide on purpose — neither door may
  # offer it.
  test "money the reader cannot reach opens no door to the spend dialog" do
    account = Account.create!(
      family: @user.family, owner: users(:family_member), accountable: Depository.new,
      name: "Member Only Pot", currency: "USD", balance: 5_000
    )
    goal = @user.family.goals.create!(name: "Hidden", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 5_000)
    end

    get goal_url(goal)

    assert_response :success
    assert goal.current_balance.to_d.positive?, "the goal is backed, just not for this reader"
    assert_empty css_select("a[href='#{consume_goal_path(goal)}']"),
      "a spend was still offered against money the reader cannot see"
  end

  private

    def spent_goal_for_display
      account = Account.create!(
        family: @user.family, accountable: Depository.new,
        name: "Spent Pot", currency: "USD", balance: 5_000
      )
      goal = @user.family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: 5_000)
      end
      goal.consume!(2_000)
      goal
    end

    def reached_goal_holding_money
      account = Account.create!(
        family: @user.family, accountable: Depository.new,
        name: "Reached Pot", currency: "USD", balance: 5_000
      )
      @user.family.goals.create!(name: "Trip", target_amount: 5_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: 5_000)
      end
    end
    # SQL the pooled-allocation read issues, and nothing else: goal_accounts
    # joined to goals.
    def count_pool_queries
      count = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        count += 1 if sql.include?("FROM \"goal_accounts\"") && sql.include?("INNER JOIN \"goals\"")
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end


    # The row must carry both readings, since one of them is invisible to the
    # other: a whole-account claim elsewhere sums to zero, and without the flag
    # the form would tell the user the account is theirs alone and then refuse
    # the blank allocation on submit.
    test "each account row carries the whole-account claim as well as the sum" do
      account = unclaimed_account("Claimed Pot")
      @user.family.goals.create!(name: "Neighbour", target_amount: 5_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account)
      end

      get new_goal_url

      assert_response :success
      assert_match(/data-earmarked-by-others="0(\.0)?"[^>]*data-whole-account-claimed="true"/m, response.body)
    end

    # The hint for a blank amount is chosen client-side from two strings the
    # form hands over. A missing one does not raise — the value reads as
    # undefined and the line renders empty — so the wiring is what needs
    # pinning, not the ternary that picks between them.
    test "the form carries both blank-amount hints" do
      unclaimed_account("Hint Pot")

      get new_goal_url

      assert_response :success
      # Escaped: the copy carries an apostrophe, and the attribute value in the
      # response is HTML-escaped.
      assert_includes response.body, ERB::Util.html_escape(I18n.t("goals.form.earmark.whole_balance_alone"))
      assert_includes response.body, ERB::Util.html_escape(I18n.t("goals.form.earmark.whole_balance"))
    end

    # The two must stay distinguishable: if they ever say the same thing, the
    # branch is doing nothing and a first-time user is back to being told about
    # earmarks that do not exist.
    test "the two blank-amount hints say different things" do
      assert_not_equal I18n.t("goals.form.earmark.whole_balance"),
                       I18n.t("goals.form.earmark.whole_balance_alone")
      assert_no_match(/earmark/i, I18n.t("goals.form.earmark.whole_balance_alone"),
        "the hint shown with no other claims should not mention earmarks")
    end

  private

    # A private account of another member, linked to the goal under test.
    def private_linked_account
      account = Account.create!(
        family: @user.family,
        owner: users(:family_member),
        accountable: Depository.new,
        name: "Member Private Checking",
        currency: @goal.currency,
        balance: 1_000
      )
      @goal.goal_accounts.create!(account: account, allocated_amount: 500)
      account
    end

    def goal_with_outflow
      account = Account.create!(
        family: @user.family, accountable: Depository.new,
        name: "Trip Pot #{SecureRandom.hex(4)}", currency: @user.family.currency, balance: 5_000
      )
      goal = @user.family.goals.create!(
        name: "Trip", target_amount: 5_000, currency: @user.family.currency
      ) { |g| g.goal_accounts.build(account: account, allocated_amount: 5_000) }
      entry = account.entries.create!(
        name: "Flights", date: Date.current, amount: 1_200,
        currency: account.currency, entryable: Transaction.new
      )
      [ goal, entry ]
    end
    # An active one_off goal sitting exactly at its target, on an account no
    # other goal claims.
    def fully_funded_goal
      account = Account.create!(
        family: @user.family, accountable: Depository.new,
        name: "Funded Pot", currency: "USD", balance: 2_000
      )
      @user.family.goals.create!(name: "Funded", target_amount: 2_000, currency: "USD") do |g|
        g.goal_accounts.build(account: account)
      end
    end

    # A fundable account no goal fixture claims. The fixtures link
    # @depository and @connected as whole-balance earmarks, and GoalAccount
    # refuses a second whole-balance link on an account already claimed in
    # full — so any test that wants the default "dedicate the whole balance"
    # link needs an account of its own.
    def unclaimed_account(name)
      Account.create!(
        family: @user.family, accountable: Depository.new,
        name: name, currency: "USD", balance: 1_000
      )
    end

    # A goal in the state account deletion leaves behind: still present, zero
    # linked accounts, failing its own validations.
    def orphaned_goal
      family = @user.family
      throwaway = Account.create!(
        family: family, accountable: Depository.new, name: "Throwaway", currency: "USD", balance: 100
      )
      goal = family.goals.new(name: "Orphan", target_amount: 500, currency: "USD")
      goal.goal_accounts.build(account: throwaway)
      goal.save!

      throwaway.destroy!
      goal.reload
      assert_empty goal.goal_accounts, "fixture setup failed to orphan the goal"
      goal
    end

    # Each goal gets its own funding account, mirroring @depository's balance.
    # These goals used to share @depository as a whole-balance link, which
    # GoalAccount now refuses — and which was the double count in the first
    # place: every goal read the same 5,000 as if it were its own. One account
    # each keeps every goal's current_balance identical to what it was, without
    # the overlap.
    def build_goal(family, name, target_amount: 1_000_000, target_date: nil)
      funding = Account.create!(
        family: family, accountable: Depository.new,
        name: "#{name} Funding", currency: "USD", balance: @depository.balance
      )
      g = family.goals.new(name: name, target_amount: target_amount, target_date: target_date, currency: "USD")
      g.goal_accounts.build(account: funding)
      g.save!
      g
    end

  public

  test "create ignores forbidden params (family_id, state)" do
    family = users(:family_admin).family
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")

    assert_difference -> { family.goals.count }, 1 do
      post goals_url, params: {
        goal: {
          name: "Hijack target",
          target_amount: 100,
          currency: "USD",
          state: "archived",
          family_id: other_family.id,
          account_ids: [ unclaimed_account("Hijack Pot").id ]
        }
      }
    end

    goal = family.goals.order(:created_at).last
    # Strong params must strip both `state` (AASM-managed) and `family_id`
    # (cross-family pivot) — otherwise a crafted POST would create rows
    # outside the current family or skip the active-state assumption.
    assert_equal "active", goal.state
    assert_equal family.id, goal.family_id
  end

  test "another family's goal returns 404" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_account = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)
    other_goal = other_family.goals.new(name: "Foreign goal", target_amount: 100, currency: "USD")
    other_goal.goal_accounts.build(account: other_account)
    other_goal.save!

    get goal_url(other_goal)
    assert_redirected_to goals_path
    assert_equal I18n.t("goals.errors.not_found"), flash[:alert]
  end
end
