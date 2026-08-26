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

  private
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
