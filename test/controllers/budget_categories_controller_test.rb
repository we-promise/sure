require "test_helper"

class BudgetCategoriesControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)

    @budget = budgets(:one)
    @family = @budget.family

    @parent_category = Category.create!(
      name: "Bills controller test",
      family: @family,
      color: "#4da568",
      lucide_icon: "house"
    )

    @electric_category = Category.create!(
      name: "Electric controller test",
      parent: @parent_category,
      family: @family
    )

    @water_category = Category.create!(
      name: "Water controller test",
      parent: @parent_category,
      family: @family
    )

    @parent_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @parent_category,
      budgeted_spending: 500,
      currency: "USD"
    )

    @electric_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @electric_category,
      budgeted_spending: 100,
      currency: "USD"
    )

    @water_budget_category = BudgetCategory.create!(
      budget: @budget,
      category: @water_category,
      budgeted_spending: 50,
      currency: "USD"
    )
  end

  test "index marks budget form values as privacy-sensitive" do
    parent_form_selector = "##{dom_id(@parent_budget_category, :form)}"
    uncategorized_form_selector = "##{dom_id(@budget, :uncategorized_budget_category_form)}"

    get budget_budget_categories_path(@budget)

    assert_response :success
    assert_select "#{parent_form_selector} .privacy-sensitive.privacy-sensitive-interactive input##{dom_id(@parent_budget_category, :budgeted_spending)}"
    assert_select "#{parent_form_selector} p.text-secondary.privacy-sensitive", text: /\/m avg/
    assert_select "#{uncategorized_form_selector} .privacy-sensitive input[name='uncategorized']"
    assert_select "#{uncategorized_form_selector} p.text-secondary.privacy-sensitive", text: /\/m avg/
  end

  test "show localizes the abbreviated budget month and recent transaction dates" do
    ensure_tailwind_build
    users(:family_admin).update!(locale: "de")
    @budget.update!(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 31))
    create_transaction(
      date: Date.new(2026, 3, 7),
      account: accounts(:depository),
      amount: 42,
      category: @parent_category,
      name: "Synthetic March expense"
    )

    get budget_budget_category_path(@budget, @parent_budget_category)

    assert_response :success
    assert_select "dt", text: "Ausgaben Mär 2026"
    assert_select "p.text-secondary.text-xs.uppercase", text: "7. Mär"
  end

  test "show preserves the abbreviated English budget month" do
    ensure_tailwind_build
    users(:family_admin).update!(locale: "en")
    @budget.update!(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 31))

    get budget_budget_category_path(@budget, @parent_budget_category)

    assert_response :success
    assert_select "dt", text: "Mar 2026 spending"
  end

  test "updating a subcategory adjusts the parent budget by the same delta" do
    assert_changes -> { @parent_budget_category.reload.budgeted_spending.to_f }, from: 500.0, to: 550.0 do
      patch budget_budget_category_path(@budget, @electric_budget_category),
            params: { budget_category: { budgeted_spending: 150 } },
            as: :turbo_stream
    end

    assert_response :success
    assert_includes @response.body, dom_id(@parent_budget_category, :form)
  end

  test "manual parent budget remains on top of subcategory changes" do
    @parent_budget_category.update!(budgeted_spending: 900)

    assert_changes -> { @parent_budget_category.reload.budgeted_spending.to_f }, from: 900.0, to: 975.0 do
      patch budget_budget_category_path(@budget, @water_budget_category),
            params: { budget_category: { budgeted_spending: 125 } },
            as: :turbo_stream
    end
  end

  test "sibling subcategory budget form rerenders without a max allocation cap" do
    patch budget_budget_category_path(@budget, @electric_budget_category),
          params: { budget_category: { budgeted_spending: 125 } },
          as: :turbo_stream

    assert_response :success

    fragment = Nokogiri::HTML.fragment(@response.body)
    input = fragment.at_css("input##{dom_id(@water_budget_category, :budgeted_spending)}")

    assert_not_nil input
    assert_nil input["max"]
  end

  test "clearing a subcategory budget switches it back to shared and lowers the parent" do
    assert_changes -> { @parent_budget_category.reload.budgeted_spending.to_f }, from: 500.0, to: 400.0 do
      patch budget_budget_category_path(@budget, @electric_budget_category),
            params: { budget_category: { budgeted_spending: "" } },
            as: :turbo_stream
    end

    assert_equal 0.0, @electric_budget_category.reload.budgeted_spending.to_f
  end

  test "toggling rollover persists and recomputes the chain" do
    previous_budget = Budget.find_or_bootstrap(@family, start_date: 1.month.ago)
    previous_budget.update!(budgeted_spending: 5000, expected_income: 7000)
    previous_budget_category = previous_budget.budget_categories.find_by!(category: @parent_category)
    previous_budget_category.update!(budgeted_spending: 400, rollover_enabled: true)

    create_transaction(
      date: previous_budget.start_date,
      account: accounts(:depository),
      amount: 150,
      category: @parent_category
    )

    patch budget_budget_category_path(@budget, @parent_budget_category),
          params: { budget_category: { budgeted_spending: 500, rollover_enabled: "1" } },
          as: :turbo_stream

    assert_response :success
    assert @parent_budget_category.reload.rollover_enabled?
    assert_equal 250.0, @parent_budget_category[:rolled_over_amount].to_f

    patch budget_budget_category_path(@budget, @parent_budget_category),
          params: { budget_category: { budgeted_spending: 500, rollover_enabled: "0" } },
          as: :turbo_stream

    assert_response :success
    assert_not @parent_budget_category.reload.rollover_enabled?
    assert_equal 0.0, @parent_budget_category[:rolled_over_amount].to_f
  end

  test "updating an allocation without the toggle leaves rollover off" do
    patch budget_budget_category_path(@budget, @parent_budget_category),
          params: { budget_category: { budgeted_spending: 600 } },
          as: :turbo_stream

    assert_response :success
    assert_not @parent_budget_category.reload.rollover_enabled?
    assert_equal 600.0, @parent_budget_category.budgeted_spending.to_f
  end

  test "show drilldown excludes BUDGET_EXCLUDED_KINDS transfers from recent transactions" do
    # Issue #1059: a matched depository <-> CC pair becomes
    # (cc_payment outflow + funds_movement inflow). Both kinds are in
    # BUDGET_EXCLUDED_KINDS so the budget aggregate excludes them, but
    # the per-category drilldown previously listed them anyway --
    # appearing under whatever category they retained (or under
    # Uncategorized once the matcher cleared the category). Filter
    # them out so the drilldown matches the aggregate.
    create_transaction(
      date: @budget.start_date,
      account: accounts(:depository),
      amount: 500,
      name: "BUG_1059_REPRO_OUTFLOW"
    )
    create_transaction(
      date: @budget.start_date,
      account: accounts(:credit_card),
      amount: -500,
      name: "BUG_1059_REPRO_INFLOW"
    )
    @family.auto_match_transfers!

    get budget_budget_category_path(@budget, BudgetCategory.uncategorized.id)
    assert_response :success
    refute_includes @response.body, "BUG_1059_REPRO_OUTFLOW",
      "matched cc_payment outflow must not appear in Uncategorized drilldown"
    refute_includes @response.body, "BUG_1059_REPRO_INFLOW",
      "matched funds_movement inflow must not appear in Uncategorized drilldown"
  end

  test "show and update do not leak another member's personal budget category" do
    @family.update!(personal_budgets: true)

    other_member_budget = Budget.find_or_bootstrap(@family, start_date: @budget.start_date, user: users(:family_member))
    other_budget_category = other_member_budget.budget_categories.find_by!(category: @parent_category)
    other_budget_category.update!(budgeted_spending: 999)

    get budget_budget_category_path(@budget, other_budget_category)
    assert_response :not_found

    patch budget_budget_category_path(@budget, other_budget_category),
          params: { budget_category: { budgeted_spending: 1 } },
          as: :turbo_stream
    assert_response :not_found

    assert_equal 999.0, other_budget_category.reload.budgeted_spending.to_f
  end

  test "show drilldown still lists loan_payment transfers (intentionally budget-tracked)" do
    # loan_payment is NOT in BUDGET_EXCLUDED_KINDS. The drilldown should
    # keep showing loan_payment transfers so the user can see what's
    # under Uncategorized (or whichever category they manually set).
    create_transaction(
      date: @budget.start_date,
      account: accounts(:depository),
      amount: 500,
      name: "MORTGAGE_REPRO_OUTFLOW"
    )
    create_transaction(
      date: @budget.start_date,
      account: accounts(:loan),
      amount: -500,
      name: "MORTGAGE_REPRO_INFLOW"
    )
    @family.auto_match_transfers!

    get budget_budget_category_path(@budget, BudgetCategory.uncategorized.id)
    assert_response :success
    assert_includes @response.body, "MORTGAGE_REPRO_OUTFLOW",
      "loan_payment outflow remains visible (kind is not BUDGET_EXCLUDED)"
  end

  # --- move (Lot A2) ---

  test "move shifts allocation between two envelopes and leaves the total alone" do
    source = @budget.budget_categories.find_by(category: @parent_category)
    other = Category.create!(name: "Transport controller test", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other, budgeted_spending: 100, currency: @budget.currency)
    source.update_budgeted_spending!(400)
    before = @budget.reload.allocated_spending

    post move_budget_budget_categories_path(@budget),
         params: { from_id: source.id, to_id: destination.id, budget_category_move: { amount: "150" } },
         as: :turbo_stream

    assert_response :success
    assert_equal 250, source.reload.budgeted_spending.to_i
    assert_equal 250, destination.reload.budgeted_spending.to_i
    assert_equal before, @budget.reload.allocated_spending
  end

  test "move refuses an amount the source does not have and says why" do
    source = @budget.budget_categories.find_by(category: @parent_category)
    other = Category.create!(name: "Transport controller test", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other, budgeted_spending: 0, currency: @budget.currency)
    source.update_budgeted_spending!(100)

    post move_budget_budget_categories_path(@budget),
         params: { from_id: source.id, to_id: destination.id, budget_category_move: { amount: "500" } },
         as: :turbo_stream

    assert_response :unprocessable_entity
    assert_equal 100, source.reload.budgeted_spending.to_i
    assert_equal 0, destination.reload.budgeted_spending.to_i
  end

  test "move refuses a parent to subcategory transfer" do
    parent = @budget.budget_categories.find_by(category: @parent_category)
    child = @budget.budget_categories.find_by(category: @electric_category)
    child.update_budgeted_spending!(50)
    before_parent = parent.reload.budgeted_spending

    post move_budget_budget_categories_path(@budget),
         params: { from_id: parent.id, to_id: child.id, budget_category_move: { amount: "10" } },
         as: :turbo_stream

    assert_response :unprocessable_entity
    assert_equal before_parent, parent.reload.budgeted_spending
  end

  # A move changes what each envelope has left, so it changes what the next
  # month inherits — the chain has to be rebuilt, exactly as an allocation
  # edit does.
  #
  # Twice, not once, and that is worth pinning: `set_budget` resolves the
  # budget through `Budget.find_or_bootstrap`, which already recomputes on
  # every request to this controller, and the action then recomputes after
  # the move commits. `#update` has carried the same double cost since the
  # rollover lot landed. The action itself must call it exactly once — the
  # count moving to three would mean a second call crept into #move.
  test "move recomputes the rollover chain, once of its own accord" do
    source = @budget.budget_categories.find_by(category: @parent_category)
    other = Category.create!(name: "Transport controller test", family: @family, color: "#e99537")
    destination = BudgetCategory.create!(budget: @budget, category: other, budgeted_spending: 0, currency: @budget.currency)
    source.update_budgeted_spending!(300)

    Budget::RolloverCalculator.any_instance.expects(:recompute!).twice

    post move_budget_budget_categories_path(@budget),
         params: { from_id: source.id, to_id: destination.id, budget_category_move: { amount: "100" } },
         as: :turbo_stream

    assert_response :success
  end

  test "a category from another budget cannot be reached through move" do
    source = @budget.budget_categories.find_by(category: @parent_category)
    source.update_budgeted_spending!(300)
    other_family = families(:empty)
    other_budget = Budget.find_or_bootstrap(other_family, start_date: Date.current.beginning_of_month)
    foreign_category = other_family.categories.create!(name: "Foreign", color: "#e99537")
    foreign = BudgetCategory.create!(budget: other_budget, category: foreign_category, budgeted_spending: 0, currency: other_budget.currency)

    post move_budget_budget_categories_path(@budget),
         params: { from_id: source.id, to_id: foreign.id, budget_category_move: { amount: "10" } },
         as: :turbo_stream

    assert_response :not_found
    assert_equal 0, foreign.reload.budgeted_spending.to_i
  end
end

class BudgetCategoriesControllerSharingTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:empty)
    @family.update!(personal_budgets: true)
    @owner = users(:josh)
    @viewer = users(:ann)
    @date = Date.current.beginning_of_month
    @family.categories.create!(name: "Groceries", color: "#6172F3")
    @owner_budget = Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
  end

  test "a read_only viewer cannot reach the categories wizard for the owner's budget" do
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")
    sign_in @viewer

    get budget_budget_categories_path(@owner_budget, owner: @owner.id)

    assert_response :not_found
  end

  test "a read_write viewer can update a category on the owner's budget" do
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_write")
    budget_category = @owner_budget.budget_categories.first
    sign_in @viewer

    patch budget_budget_category_path(@owner_budget, budget_category, owner: @owner.id),
          params: { budget_category: { budgeted_spending: 250 } },
          as: :turbo_stream

    assert_response :success
    assert_equal 250.0, budget_category.reload.budgeted_spending.to_f
  end

  test "a read_only viewer cannot move money on the owner's budget" do
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")
    categories = @owner_budget.budget_categories.to_a
    source = categories.first
    source.update_budgeted_spending!(200)
    destination = @family.categories.create!(name: "Transport", color: "#e99537")
    target = BudgetCategory.create!(budget: @owner_budget, category: destination, budgeted_spending: 0, currency: @owner_budget.currency)
    sign_in @viewer

    post move_budget_budget_categories_path(@owner_budget, owner: @owner.id),
         params: { from_id: source.id, to_id: target.id, budget_category_move: { amount: "50" } },
         as: :turbo_stream

    assert_response :not_found
    assert_equal 200, source.reload.budgeted_spending.to_i
  end
end
