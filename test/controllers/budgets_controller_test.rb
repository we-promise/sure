require "test_helper"

class BudgetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "index redirects to the current month budget" do
    get budgets_url

    assert_redirected_to budget_path(Budget.date_to_param(Date.current))
  end

  test "show renders the budget page" do
    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
  end

  test "show reconciles parent overage without marking shared children over budget" do
    budget = budgets(:one)
    parent_category = Category.create!(
      name: "Vehicle budget presentation",
      family: budget.family,
      color: "#4da568",
      lucide_icon: "car"
    )
    limited_category = Category.create!(
      name: "Vehicle payment presentation",
      parent: parent_category,
      family: budget.family
    )
    shared_category = Category.create!(
      name: "Vehicle fuel presentation",
      parent: parent_category,
      family: budget.family
    )
    parent_budget_category = BudgetCategory.create!(
      budget: budget,
      category: parent_category,
      budgeted_spending: 100,
      currency: "USD"
    )
    BudgetCategory.create!(
      budget: budget,
      category: limited_category,
      budgeted_spending: 80,
      currency: "USD"
    )
    shared_budget_category = BudgetCategory.create!(
      budget: budget,
      category: shared_category,
      budgeted_spending: 0,
      currency: "USD"
    )

    Entry.create!(
      account: accounts(:depository),
      entryable: Transaction.create!(category: limited_category),
      date: Date.current,
      name: "Vehicle payment expense",
      amount: 1,
      currency: "USD"
    )
    Entry.create!(
      account: accounts(:depository),
      entryable: Transaction.create!(category: parent_category),
      date: Date.current,
      name: "Vehicle parent expense",
      amount: 190.90,
      currency: "USD"
    )

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", budget_budget_category_path(budget, parent_budget_category), text: /Over by:\s*\$91\.90/
    assert_select "a[href=?]", budget_budget_category_path(budget, shared_budget_category), count: 0
  end

  test "show displays ring-fenced child carry on the parent card" do
    budget = budgets(:one)
    parent_category = budget.family.categories.create!(name: "Parent rollover card", color: "#4da568")
    child_category = budget.family.categories.create!(name: "Child rollover card", parent: parent_category)
    previous_budget = budget.family.budgets.create!(
      start_date: 6.months.ago.beginning_of_month.to_date,
      end_date: 6.months.ago.end_of_month.to_date,
      budgeted_spending: 20,
      expected_income: 100,
      currency: "USD"
    )
    previous_budget.budget_categories.create!(
      category: parent_category, budgeted_spending: 20, currency: "USD"
    )
    previous_budget.budget_categories.create!(
      category: child_category, budgeted_spending: 20, currency: "USD", rollover_enabled: true
    )
    parent_budget_category = budget.budget_categories.create!(
      category: parent_category, budgeted_spending: 100, currency: "USD"
    )
    budget.budget_categories.create!(
      category: child_category, budgeted_spending: 100, currency: "USD", rollover_enabled: true
    )

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", budget_budget_category_path(budget, parent_budget_category),
                  text: /\+\$20\.00 rolled over/
  end

  test "breadcrumbs include the Plan hub for preview users" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, minimum: 1
  end

  test "renders no Plan links without preview features" do
    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, count: 0
    assert_select "a[href=?]", budgets_path, minimum: 1
  end
  # --- Lot A3: cash on hand ---

  test "the cash panel is hidden without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get budget_url(Budget.date_to_param(Date.current.beginning_of_month))

    assert_response :success
    assert_no_match I18n.t("budgets.available_cash.heading"), response.body
  end

  test "the cash panel shows what goals have already claimed" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get budget_url(Budget.date_to_param(Date.current.beginning_of_month))

    assert_response :success
    assert_match I18n.t("budgets.available_cash.heading"), response.body
    assert_match I18n.t("budgets.available_cash.free"), response.body
  end
end

class BudgetsControllerSharingTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:empty)
    @family.update!(personal_budgets: true)
    @owner = users(:josh)
    @viewer = users(:ann)
    @date = Date.current.beginning_of_month
  end

  test "household budget is viewable and editable by any family member" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner, household: true)
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: "household" })
    assert_response :success

    patch budget_url(Budget.date_to_param(@date), params: { owner: "household" }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }
    assert_response :redirect
  end

  test "household tab is unreachable once household_budget_enabled is off, falling back to the viewer's own budget" do
    @family.update!(household_budget_enabled: false)
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: "household" })

    assert_response :success
    assert_equal @viewer.id, Budget.find_by(family: @family, start_date: @date).user_id
  end

  test "a member without a BudgetShare cannot view another member's personal budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: @owner.id })

    # Falls back to the viewer's own budget rather than the owner's.
    assert_response :success
    assert Budget.exists?(family: @family, start_date: @date, user_id: @viewer.id)
  end

  test "a read_only BudgetShare lets the viewer see but not edit the owner's budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: @owner.id })
    assert_response :success

    get edit_budget_url(Budget.date_to_param(@date), params: { owner: @owner.id })
    assert_response :not_found

    patch budget_url(Budget.date_to_param(@date), params: { owner: @owner.id }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }
    assert_response :not_found
  end

  test "a read_write BudgetShare lets the viewer edit the owner's budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_write")
    sign_in @viewer

    patch budget_url(Budget.date_to_param(@date), params: { owner: @owner.id }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }

    assert_redirected_to budget_budget_categories_url(Budget.date_to_param(@date), owner: @owner.id)
    assert_equal 1000, Budget.find_by(family: @family, user: @owner).budgeted_spending.to_i
  end
end
