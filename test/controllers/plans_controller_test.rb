require "test_helper"

class PlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    ensure_tailwind_build
  end


  # The status pill beside this bar was already amber for a depleted reserve
  # while the bar itself stayed neutral: the same goal reported as needing
  # attention and not, an inch apart.
  #
  # Counted rather than matched: a fixture goal is already off its pace, so
  # the markup is on the page either way and a presence check passes without
  # the fix.
  test "the goals card bars a depleted reserve in warning colour" do
    bar = /h-full bg-warning rounded-full/

    get plan_url
    before = response.body.scan(bar).size

    family = @user.family
    account = Account.create!(family: family, accountable: Depository.new,
                              name: "Reserve pot", currency: family.currency, balance: 1_000)
    family.goals.create!(name: "Precaution", target_amount: 6_000,
                         currency: family.currency, kind: "maintained") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end

    get plan_url

    assert_response :success
    assert_equal before + 1, response.body.scan(bar).size,
                 "the depleted reserve's bar stayed neutral"
  end

  test "redirects users without preview access to budgets" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get plan_url

    assert_redirected_to budgets_path
  end

  test "renders budget and goals summary cards with drill-in links" do
    get plan_url

    assert_response :success
    assert_match I18n.t("plans.budget_card.title"), response.body
    assert_match I18n.t("plans.goals_card.title"), response.body
    assert_select "a[href=?]", budget_path(Budget.date_to_param(Date.current))
    assert_select "a[href=?]", goals_path
  end

  test "lists active goals with links to their detail pages" do
    get plan_url

    assert_response :success
    goal = goals(:vacation_italy)
    assert_match goal.name, response.body
    assert_select "a[href=?]", goal_path(goal)
  end

  test "shows the goals empty state when the family has no goals" do
    @user.family.goals.destroy_all

    get plan_url

    assert_response :success
    assert_match I18n.t("goals.empty_state.body"), response.body
    assert_select "a[href=?]", goals_path, count: 0
  end

  test "keeps the all-goals link when only completed or archived goals remain" do
    @user.family.goals.each { |goal| goal.update_columns(state: "archived") }

    get plan_url

    assert_response :success
    assert_match I18n.t("goals.empty_state.body"), response.body
    assert_select "a[href=?]", goals_path, minimum: 1
  end

  # Bills lives in the hub, not the nav, for the users who see the hub.
  test "fronts Bills with a hub card instead of a nav entry" do
    get plan_url

    assert_response :success
    assert_select "main h2", text: I18n.t("plans.bills_card.title")
    assert_select "main a[href=?]", bills_path
    assert_select "nav a[href=?]", bills_path, count: 0
    assert_select "nav a[href=?][aria-current=page]", plan_path, minimum: 1
  end

  test "keeps the Plan nav entry lit on the Bills page" do
    get bills_url

    assert_response :success
    assert_select "nav a[href=?][aria-current=page]", plan_path, minimum: 1
  end

  test "the bills card counts what is owed this month" do
    next_month = Date.current.next_month.beginning_of_month
    series = recurring_transactions(:netflix_subscription)
    series.recurring_occurrences.create!(family: @user.family, original_due_on: next_month, due_on: next_month, currency: "USD")

    get plan_url
    assert_select "main p", text: I18n.t("plans.bills_card.nothing_owed")

    series.recurring_occurrences.create!(family: @user.family, original_due_on: Date.current, due_on: Date.current, currency: "USD")

    get plan_url
    assert_select "main p", text: I18n.t("plans.bills_card.owed_count", count: 1)
  end

  # An upgraded instance has series but no occurrence rows until something
  # generates them, and Plan is now the way into Bills.
  test "the bills card counts an upgraded family's bills before Bills was ever opened" do
    @user.family.recurring_transactions.create!(
      name: "Rent", account: accounts(:depository), amount: 1200, currency: "USD",
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current, status: "active", manual: true
    )
    @user.family.recurring_occurrences.delete_all

    get plan_url

    assert_response :success
    assert_operator @user.family.recurring_occurrences.count, :>, 0
    assert_select "main p", text: I18n.t("plans.bills_card.nothing_owed"), count: 0
  end

  # The card headers' trailing counts are the easiest strings to lose to a
  # lazy lookup resolving against the wrong template, and a missing key
  # renders a humanized fallback rather than failing.
  test "card headers carry their own translated counts" do
    recurring_transactions(:netflix_subscription).recurring_occurrences.create!(
      family: @user.family, original_due_on: Date.current - 10, due_on: Date.current - 10, currency: "USD"
    )

    get plan_url

    assert_response :success
    assert_select "main span", text: "· #{I18n.t("plans.goals_card.active_count", count: Goal.active_prepared_for(@user.family).size)}"
    assert_select "main", text: /#{I18n.t("plans.bills_card.overdue_count", count: 1)}/
    assert_no_match(/translation_missing/, response.body)
  end

  test "drops the bills card while recurring detection is off" do
    @user.family.update!(recurring_transactions_disabled: true)

    get plan_url

    assert_response :success
    assert_select "main h2", text: I18n.t("plans.bills_card.title"), count: 0
    assert_select "a[href=?]", bills_path, count: 0
  end

  test "shows the budget setup CTA when the month is uninitialized" do
    budgets(:one).update!(budgeted_spending: nil)

    get plan_url

    assert_response :success
    assert_match I18n.t("plans.budget_card.empty_body"), response.body
    assert_select "a[href=?]", edit_budget_path(Budget.date_to_param(Date.current))
  end
end

class PlansControllerHouseholdSwitchingTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:empty)
    @family.update!(personal_budgets: true)
    @owner = users(:josh)
    @owner.update!(preferences: (@owner.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @owner
    ensure_tailwind_build
  end

  test "renders a household/mine switcher once personal_budgets is on, and switches to household" do
    get plan_url

    assert_response :success
    assert_select "a[href=?]", plan_path(owner: "household")
    assert_select "a[href=?]", plan_path(owner: @owner.id)

    get plan_url, params: { owner: "household" }
    assert_response :success
  end

  test "hides the household pill when household_budget_enabled is off" do
    @family.update!(household_budget_enabled: false)

    get plan_url

    assert_response :success
    assert_select "a[href=?]", plan_path(owner: "household"), count: 0
  end
end
