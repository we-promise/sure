require "test_helper"

class GoalsControllerTest < ActionDispatch::IntegrationTest
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
    assert_difference -> { Goal.count } => 1,
                      -> { GoalAccount.count } => 2 do
      post goals_url, params: {
        goal: {
          name: "New goal",
          target_amount: "1000",
          target_date: 3.months.from_now.to_date.iso8601,
          color: "#4da568",
          account_ids: [ @depository.id, @connected.id ]
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

  test "destroy on non-archived is rejected" do
    assert_no_difference "Goal.count" do
      delete goal_url(@goal)
    end
    assert_redirected_to goal_path(@goal)
  end

  test "destroy on archived deletes" do
    @goal.archive!
    assert_difference "Goal.count", -1 do
      delete goal_url(@goal)
    end
    assert_redirected_to goals_path
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

  private
    def build_goal(family, name, target_amount: 1_000_000, target_date: nil)
      g = family.goals.new(name: name, target_amount: target_amount, target_date: target_date, currency: "USD")
      g.goal_accounts.build(account: @depository)
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
          account_ids: [ @depository.id ]
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
