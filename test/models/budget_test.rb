require "test_helper"

class BudgetTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "budget_date_valid? allows going back 2 years even without entries" do
    two_years_ago = 2.years.ago.beginning_of_month
    assert Budget.budget_date_valid?(two_years_ago, family: @family)
  end

  test "budget_date_valid? allows going back to earliest entry date if more than 2 years ago" do
    # Create an entry 3 years ago
    old_account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Old Account",
      status: "active",
      currency: "USD",
      balance: 1000
    )

    old_entry = Entry.create!(
      account: old_account,
      entryable: Transaction.new(category: categories(:income)),
      date: 3.years.ago,
      name: "Old Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should allow going back to the old entry date
    assert Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? does not allow dates before earliest entry or 2 years ago" do
    # Create an entry 1 year ago
    account = Account.create!(
      family: @family,
      accountable: Depository.new,
      name: "Test Account",
      status: "active",
      currency: "USD",
      balance: 500
    )

    Entry.create!(
      account: account,
      entryable: Transaction.new(category: categories(:income)),
      date: 1.year.ago,
      name: "Recent Transaction",
      amount: 100,
      currency: "USD"
    )

    # Should not allow going back more than 2 years
    refute Budget.budget_date_valid?(3.years.ago.beginning_of_month, family: @family)
  end

  test "budget_date_valid? allows future dates up to 2 years ahead" do
    travel_to Date.current.beginning_of_month do
      assert Budget.budget_date_valid?(Date.current.beginning_of_month + 1.month, family: @family)
      assert Budget.budget_date_valid?(Date.current.beginning_of_month + 2.years, family: @family)
    end
  end

  test "budget_date_valid? does not allow future dates beyond 2 years ahead" do
    travel_to Date.current.beginning_of_month do
      refute Budget.budget_date_valid?(Date.current.beginning_of_month + 2.years + 1.month, family: @family)
    end
  end

  test "budget_date_valid? for custom month start allows dates up to 2 years ahead" do
    @family.update!(month_start_day: 15)

    travel_to Date.current.beginning_of_month do
      cap_start = @family.current_custom_month_period.start_date + 2.years
      assert Budget.budget_date_valid?(cap_start, family: @family)
    end
  end

  test "budget_date_valid? for custom month start does not allow dates beyond 2 years ahead" do
    @family.update!(month_start_day: 15)

    travel_to Date.current.beginning_of_month do
      beyond_cap = @family.current_custom_month_period.start_date + 2.years + 1.month
      refute Budget.budget_date_valid?(beyond_cap, family: @family)
    end
  end

  test "previous_budget_param returns nil when date is too old" do
    # Create a budget at the oldest allowed date
    two_years_ago = 2.years.ago.beginning_of_month
    budget = Budget.create!(
      family: @family,
      start_date: two_years_ago,
      end_date: two_years_ago.end_of_month,
      currency: "USD"
    )

    assert_nil budget.previous_budget_param
  end

  test "next_budget_param returns next month when current month budget is selected" do
    travel_to Date.current.beginning_of_month do
      budget = Budget.create!(
        family: @family,
        start_date: Date.current.beginning_of_month,
        end_date: Date.current.end_of_month,
        currency: "USD"
      )

      assert_equal Budget.date_to_param(Date.current.beginning_of_month + 1.month), budget.next_budget_param
    end
  end

  test "next_budget_param returns nil at future cap" do
    travel_to Date.current.beginning_of_month do
      cap_start = Date.current.beginning_of_month + 2.years
      budget = Budget.create!(
        family: @family,
        start_date: cap_start,
        end_date: cap_start.end_of_month,
        currency: "USD"
      )

      assert_nil budget.next_budget_param
    end
  end

  test "next_budget_param returns nil at future cap for custom month start" do
    @family.update!(month_start_day: 15)

    travel_to Date.current.beginning_of_month do
      cap_start = @family.current_custom_month_period.start_date + 2.years
      budget = Budget.create!(
        family: @family,
        start_date: cap_start,
        end_date: cap_start + 1.month - 1.day,
        currency: "USD"
      )

      assert_nil budget.next_budget_param
    end
  end

  test "actual_spending nets refunds against expenses in same category" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)

    healthcare = Category.create!(
      name: "Healthcare #{Time.now.to_f}",
      family: family,
      color: "#e74c3c"
    )

    budget.sync_budget_categories
    budget_category = budget.budget_categories.find_by(category: healthcare)
    budget_category.update!(budgeted_spending: 200)

    account = accounts(:depository)

    # Create a $500 expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: healthcare),
      date: Date.current,
      name: "Doctor visit",
      amount: 500,
      currency: "USD"
    )

    # Create a $200 refund (negative amount = income classification in the SQL)
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: healthcare),
      date: Date.current,
      name: "Insurance reimbursement",
      amount: -200,
      currency: "USD"
    )

    # Clear memoized values
    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    # Budget category should show net spending: $500 - $200 = $300
    assert_equal 300, budget.budget_category_actual_spending(
      budget.budget_categories.find_by(category: healthcare)
    )
  end

  test "budget_category_actual_spending does not go below zero" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)

    category = Category.create!(
      name: "Returns Only #{Time.now.to_f}",
      family: family,
      color: "#3498db"
    )

    budget.sync_budget_categories
    budget_category = budget.budget_categories.find_by(category: category)
    budget_category.update!(budgeted_spending: 100)

    account = accounts(:depository)

    # Only a refund, no expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Full refund",
      amount: -50,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    assert_equal 0, budget.budget_category_actual_spending(
      budget.budget_categories.find_by(category: category)
    )
  end

  test "to_donut_segments_json only includes top-level budget categories" do
    family = @family
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)
    budget.update!(budgeted_spending: 500, currency: family.currency)

    parent_category = Category.create!(
      name: "Transport #{Time.now.to_f}",
      family: family,
      color: "#6471eb"
    )

    child_category = Category.create!(
      name: "Petrol #{Time.now.to_f}",
      family: family,
      parent: parent_category,
      color: "#61c9ea"
    )

    standalone_category = Category.create!(
      name: "Shopping #{Time.now.to_f}",
      family: family,
      color: "#df4e92"
    )

    budget.sync_budget_categories

    parent_budget_category = budget.budget_categories.find_by!(category: parent_category)
    child_budget_category = budget.budget_categories.find_by!(category: child_category)
    standalone_budget_category = budget.budget_categories.find_by!(category: standalone_category)

    parent_budget_category.update!(budgeted_spending: 150, currency: family.currency)
    child_budget_category.update!(budgeted_spending: 50, currency: family.currency)
    standalone_budget_category.update!(budgeted_spending: 100, currency: family.currency)

    budget.stubs(:allocations_valid?).returns(true)
    budget.stubs(:available_to_spend).returns(200)
    budget.stubs(:budget_category_actual_spending).with(parent_budget_category).returns(63.11)
    budget.stubs(:budget_category_actual_spending).with(standalone_budget_category).returns(25)
    budget.stubs(:budget_category_actual_spending).with(budget.uncategorized_budget_category).returns(0)

    segments = budget.to_donut_segments_json

    segment_ids = segments.pluck(:id)
    segments_by_id = segments.index_by { |segment| segment[:id] }

    assert_equal 3, segments.size
    assert_includes segment_ids, parent_budget_category.id
    assert_includes segment_ids, standalone_budget_category.id
    assert_includes segment_ids, "unused"
    refute_includes segment_ids, child_budget_category.id

    assert_equal 63.11, segments_by_id[parent_budget_category.id][:amount]
    assert_equal 25, segments_by_id[standalone_budget_category.id][:amount]
    assert_equal 200, segments_by_id["unused"][:amount]
  end

  test "to_donut_segments_json includes uncategorized spending" do
    family = @family
    account = Account.create!(
      family: family,
      accountable: Depository.new,
      name: "Checking",
      status: "active",
      currency: "USD",
      balance: 0
    )

    category = Category.create!(
      name: "Groceries #{Time.now.to_f}",
      family: family,
      color: "#407706",
      lucide_icon: "shopping-bag"
    )

    budget = Budget.create!(
      family: family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD",
      budgeted_spending: 100
    )

    BudgetCategory.create!(
      budget: budget,
      category: category,
      budgeted_spending: 100,
      currency: "USD"
    )

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Uncategorized donut spending",
      amount: 125,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    uncategorized = budget.uncategorized_budget_category
    segments = budget.to_donut_segments_json
    uncategorized_segment = segments.find { |segment| segment[:id] == uncategorized.id }

    assert_equal 125, budget.actual_spending
    assert_equal 125, uncategorized.actual_spending
    assert_not_nil uncategorized_segment
    assert_equal 125, uncategorized_segment[:amount]
  end

  test "actual_spending subtracts uncategorized refunds" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)
    account = accounts(:depository)

    # Create an uncategorized expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Uncategorized purchase",
      amount: 400,
      currency: "USD"
    )

    # Create an uncategorized refund
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Uncategorized refund",
      amount: -150,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    # The uncategorized refund should reduce overall actual_spending
    # Other fixtures may contribute spending, so check that the net
    # uncategorized amount (400 - 150 = 250) is reflected by comparing
    # with and without the refund rather than asserting an exact total.
    spending_with_refund = budget.actual_spending

    # Remove the refund and check spending increases
    Entry.find_by(name: "Uncategorized refund").destroy!
    budget = Budget.find(budget.id)
    spending_without_refund = budget.actual_spending

    assert_equal 150, spending_without_refund - spending_with_refund
  end

  test "most_recent_initialized_budget returns latest initialized budget before this one" do
    family = families(:dylan_family)

    # Create an older initialized budget (2 months ago)
    older_budget = Budget.create!(
      family: family,
      start_date: 2.months.ago.beginning_of_month,
      end_date: 2.months.ago.end_of_month,
      budgeted_spending: 3000,
      expected_income: 5000,
      currency: "USD"
    )

    # Create a middle uninitialized budget (1 month ago)
    Budget.create!(
      family: family,
      start_date: 1.month.ago.beginning_of_month,
      end_date: 1.month.ago.end_of_month,
      currency: "USD"
    )

    current_budget = Budget.find_or_bootstrap(family, start_date: Date.current)

    assert_equal older_budget, current_budget.most_recent_initialized_budget
  end

  test "most_recent_initialized_budget returns nil when none exist" do
    family = families(:empty)
    budget = Budget.create!(
      family: family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_nil budget.most_recent_initialized_budget
  end

  test "copy_from copies budgeted_spending expected_income and matching category budgets" do
    family = families(:dylan_family)

    # Use past months to avoid fixture conflict (fixture :one is at Date.current for dylan_family)
    source_budget = Budget.find_or_bootstrap(family, start_date: 2.months.ago)
    source_budget.update!(budgeted_spending: 4000, expected_income: 6000)
    source_bc = source_budget.budget_categories.find_by(category: categories(:food_and_drink))
    source_bc.update!(budgeted_spending: 500)

    target_budget = Budget.find_or_bootstrap(family, start_date: 1.month.ago)
    assert_nil target_budget.budgeted_spending

    target_budget.copy_from!(source_budget)
    target_budget.reload

    assert_equal 4000, target_budget.budgeted_spending
    assert_equal 6000, target_budget.expected_income

    target_bc = target_budget.budget_categories.find_by(category: categories(:food_and_drink))
    assert_equal 500, target_bc.budgeted_spending
  end

  test "copy_from skips categories that dont exist in target" do
    family = families(:dylan_family)

    source_budget = Budget.find_or_bootstrap(family, start_date: 2.months.ago)
    source_budget.update!(budgeted_spending: 4000, expected_income: 6000)

    # Create a category only in the source budget
    temp_category = Category.create!(name: "Temp #{Time.now.to_f}", family: family, color: "#aaaaaa")
    source_budget.budget_categories.create!(category: temp_category, budgeted_spending: 100, currency: "USD")

    target_budget = Budget.find_or_bootstrap(family, start_date: 1.month.ago)

    # Should not raise even though target doesn't have the temp category
    assert_nothing_raised { target_budget.copy_from!(source_budget) }
    assert_equal 4000, target_budget.reload.budgeted_spending
  end

  test "copy_from leaves new categories at zero" do
    family = families(:dylan_family)

    source_budget = Budget.find_or_bootstrap(family, start_date: 2.months.ago)
    source_budget.update!(budgeted_spending: 4000, expected_income: 6000)

    target_budget = Budget.find_or_bootstrap(family, start_date: 1.month.ago)

    # Add a new category only to the target
    new_category = Category.create!(name: "New #{Time.now.to_f}", family: family, color: "#bbbbbb")
    target_budget.budget_categories.create!(category: new_category, budgeted_spending: 0, currency: "USD")

    target_budget.copy_from!(source_budget)

    new_bc = target_budget.budget_categories.find_by(category: new_category)
    assert_equal 0, new_bc.budgeted_spending
  end

  test "previous_budget_param returns param when date is valid" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_not_nil budget.previous_budget_param
  end

  test "uncategorized budget category actual spending reflects uncategorized transactions" do
    family = families(:dylan_family)
    budget = Budget.find_or_bootstrap(family, start_date: Date.current.beginning_of_month)
    account = accounts(:depository)

    # Create an uncategorized expense
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: nil),
      date: Date.current,
      name: "Uncategorized lunch",
      amount: 75,
      currency: "USD"
    )

    budget = Budget.find(budget.id)
    budget.sync_budget_categories

    uncategorized_bc = budget.uncategorized_budget_category
    spending = budget.budget_category_actual_spending(uncategorized_bc)

    # Must be > 0 — the nil-key collision between Uncategorized and
    # Other Investments synthetic categories previously caused this to return 0
    assert spending >= 75, "Uncategorized actual spending should include the $75 transaction, got #{spending}"
  end

  test "days_remaining counts today through the end of the period" do
    budget = budgets(:one)

    travel_to budget.start_date do
      assert_equal (budget.end_date - budget.start_date).to_i + 1, budget.days_remaining
    end

    travel_to budget.end_date do
      assert_equal 1, budget.days_remaining
    end

    travel_to budget.end_date + 1.day do
      assert_equal 0, budget.days_remaining
    end
  end

  # ---------------------------------------------------------------------------
  # Budget plans (multiple budgets per month)
  # ---------------------------------------------------------------------------

  test "creating a budget without a plan attaches it to the family's default plan" do
    budget = Budget.create!(
      family: @family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )

    assert_equal @family.default_budget_plan, budget.budget_plan
  end

  test "two plans can hold budgets for the same month but one plan cannot" do
    plan_a = @family.default_budget_plan
    plan_b = @family.budget_plans.create!(name: "Test")

    Budget.create!(family: @family, budget_plan: plan_a, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, currency: "USD")
    sibling = Budget.create!(family: @family, budget_plan: plan_b, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, currency: "USD")
    assert sibling.persisted?

    duplicate = Budget.new(family: @family, budget_plan: plan_b, start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month, currency: "USD")
    assert_not duplicate.valid?
    assert duplicate.errors[:start_date].any?
  end

  test "find_or_bootstrap with a plan returns that plan's budget" do
    plan = @family.budget_plans.create!(name: "Test")

    default_budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    plan_budget = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)

    assert_not_equal default_budget.id, plan_budget.id
    assert_equal plan.id, plan_budget.budget_plan_id
    assert_equal plan_budget.id, Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan).id
  end

  test "find_or_bootstrap rejects a plan from another family" do
    other_plan = families(:dylan_family).budget_plans.create!(name: "Foreign")

    assert_raises ArgumentError do
      Budget.find_or_bootstrap(@family, start_date: Date.current, plan: other_plan)
    end
  end

  test "to_param is the bare month slug for the default plan and plan-qualified otherwise" do
    default_budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    assert_equal Budget.date_to_param(Date.current), default_budget.to_param

    plan = @family.budget_plans.create!(name: "Joint Accounts")
    plan_budget = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)
    assert_equal "joint-accounts-#{Budget.date_to_param(Date.current)}", plan_budget.to_param
  end

  test "resolve_param round-trips both param shapes including multi-dash slugs" do
    plan = @family.budget_plans.create!(name: "Side Hustle Fund")
    date = Date.current.beginning_of_month

    resolved_plan, resolved_date = Budget.resolve_param(Budget.date_to_param(date), family: @family)
    assert resolved_plan.is_default?
    assert_equal date, resolved_date

    resolved_plan, resolved_date = Budget.resolve_param("side-hustle-fund-#{Budget.date_to_param(date)}", family: @family)
    assert_equal plan, resolved_plan
    assert_equal date, resolved_date
  end

  test "resolve_param raises RecordNotFound for malformed params and unknown slugs" do
    assert_raises ActiveRecord::RecordNotFound do
      Budget.resolve_param("not-a-real-param", family: @family)
    end

    assert_raises ActiveRecord::RecordNotFound do
      Budget.resolve_param("ghost-#{Budget.date_to_param(Date.current)}", family: @family)
    end
  end

  test "resolve_param raises RecordNotFound for well-shaped but impossible month tokens" do
    plan = @family.budget_plans.create!(name: "Real")

    assert_raises ActiveRecord::RecordNotFound do
      Budget.resolve_param("abc-2026", family: @family)
    end

    assert_raises ActiveRecord::RecordNotFound do
      Budget.resolve_param("real-abc-2026", family: @family)
    end
  end

  test "rejects direct creation against another family's plan" do
    foreign_plan = budget_plans(:dylan_default)

    budget = @family.budgets.build(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD",
      budget_plan: foreign_plan
    )

    assert_not budget.valid?
    assert budget.errors[:budget_plan].any?
  end

  test "previous and next budget params carry the plan slug" do
    plan = @family.budget_plans.create!(name: "Test")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)

    assert_equal "test-#{Budget.date_to_param(Date.current - 1.month)}", budget.previous_budget_param
    assert_equal "test-#{Budget.date_to_param(Date.current + 1.month)}", budget.next_budget_param
  end

  test "most_recent_initialized_budget stays within the budget's plan" do
    plan = @family.budget_plans.create!(name: "Test")

    Budget.create!(
      family: @family,
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: 1.month.ago.end_of_month.to_date,
      budgeted_spending: 1000,
      currency: "USD"
    )

    plan_budget = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)
    assert_nil plan_budget.most_recent_initialized_budget

    default_budget = Budget.find_or_bootstrap(@family, start_date: Date.current)
    assert_not_nil default_budget.most_recent_initialized_budget
  end

  test "copy_from! rejects a source budget from another plan" do
    plan = @family.budget_plans.create!(name: "Test")

    source = Budget.create!(
      family: @family,
      start_date: 1.month.ago.beginning_of_month.to_date,
      end_date: 1.month.ago.end_of_month.to_date,
      budgeted_spending: 1000,
      currency: "USD"
    )
    target = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)

    assert_raises ArgumentError do
      target.copy_from!(source)
    end
  end

  test "a plan scoped to accounts only counts those accounts' transactions" do
    scoped_account = Account.create!(family: @family, accountable: Depository.new, name: "Scoped", status: "active", currency: "USD", balance: 1000)
    other_account = Account.create!(family: @family, accountable: Depository.new, name: "Unscoped", status: "active", currency: "USD", balance: 1000)

    category = Category.create!(name: "Food", family: @family, color: "#e74c3c")

    [ scoped_account, other_account ].each do |account|
      Entry.create!(
        account: account,
        entryable: Transaction.create!(category: category),
        date: Date.current,
        name: "Spend from #{account.name}",
        amount: 100,
        currency: "USD"
      )
    end

    plan = @family.budget_plans.create!(name: "Scoped")
    plan.budget_plan_accounts.create!(account: scoped_account)

    scoped_budget = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)
    default_budget = Budget.find_or_bootstrap(@family, start_date: Date.current)

    assert_equal 100, scoped_budget.actual_spending
    assert_equal 200, default_budget.actual_spending
    assert_equal 1, scoped_budget.transactions.count
    assert_equal 2, default_budget.transactions.count
  end
end
