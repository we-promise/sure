require "test_helper"

class Assistant::Function::GetBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::GetBudget.new(@user)
  end

  test "has correct name" do
    assert_equal "get_budget", @function.name
  end

  test "has a description" do
    assert_not_empty @function.description
  end

  test "is not in strict mode" do
    refute @function.strict_mode?
  end

  test "params_schema declares optional month and prior_months" do
    schema = @function.params_schema
    assert schema[:properties].key?(:month)
    assert schema[:properties].key?(:prior_months)
    assert_empty schema[:required]
  end

  test "returns current month when no month given" do
    result = @function.call({})

    assert_equal @family.currency, result[:currency]
    assert_equal 1, result[:months].length

    month = result[:months].first
    assert month[:is_current]
    assert_equal Date.current.beginning_of_month, month[:period][:start_date]
    assert_equal Date.current.end_of_month, month[:period][:end_date]
  end

  test "returns N+1 months sorted oldest first when prior_months is set" do
    current_start = Date.current.beginning_of_month
    2.times do |i|
      prior_start = current_start << (i + 1)
      Budget.create!(
        family: @family,
        start_date: prior_start,
        end_date: prior_start.end_of_month,
        currency: @family.currency
      )
    end

    result = @function.call("prior_months" => 2)

    assert_equal 3, result[:months].length
    starts = result[:months].map { |m| m[:period][:start_date] }
    assert_equal starts.sort, starts
    assert_equal current_start, starts.last
  end

  test "does not bootstrap budgets for prior_months that do not exist" do
    initial_count = Budget.count

    result = @function.call("prior_months" => 3)

    assert_equal initial_count, Budget.count, "no prior budgets should be created as a side effect"
    assert_equal 1, result[:months].length
    assert_equal 3, result[:months_unavailable]
  end

  test "clamps prior_months above MAX_PRIOR_MONTHS" do
    result = @function.call("prior_months" => 99)
    considered = result[:months].length + (result[:months_unavailable] || 0)
    assert_operator considered, :<=, Assistant::Function::GetBudget::MAX_PRIOR_MONTHS + 1
  end

  test "accepts YYYY-MM month format" do
    target = Date.current.beginning_of_month << 1
    result = @function.call("month" => target.strftime("%Y-%m"))

    assert_equal 1, result[:months].length
    assert_equal target, result[:months].first[:period][:start_date]
  end

  test "accepts MMM-YYYY month format" do
    target = Date.current.beginning_of_month << 1
    result = @function.call("month" => target.strftime("%b-%Y").downcase)

    assert_equal target, result[:months].first[:period][:start_date]
  end

  test "respects custom month_start_day so slug input roundtrips" do
    @family.update!(month_start_day: 15)
    target = Date.new(Date.current.year, Date.current.month, 15) - 2.months
    slug = target.strftime("%b-%Y").downcase

    result = @function.call("month" => slug)

    assert_equal 1, result[:months].length
    month = result[:months].first
    assert_equal slug, month[:month]
    assert_equal target, month[:period][:start_date]
  end

  test "does not leak another family member's personal budget in trend months" do
    @family.update!(personal_budgets: true)
    prior_start = Date.current.beginning_of_month << 1

    other_budget = Budget.find_or_bootstrap(@family, start_date: prior_start, user: users(:family_member))
    other_bc = other_budget.budget_categories.find { |bc| bc.category == categories(:food_and_drink) }
    other_bc.update!(budgeted_spending: 12345)

    result = @function.call("prior_months" => 1)

    assert_equal 1, result[:months].length, "another member's personal budget must not surface as a trend month"
    assert_equal 1, result[:months_unavailable]
  end

  # The assistant answers from a job, where Current.user is not set: a prior
  # household month must still count only the accounts the asker can see.
  test "trend months count only the spending on accounts the member can see" do
    prior_start = Date.current.beginning_of_month << 1
    category = @family.categories.create!(name: "Gifts", color: "#123456")
    budget = Budget.find_or_bootstrap(@family, start_date: prior_start)
    budget.budget_categories.find_by!(category: category).update!(budgeted_spending: 500)
    spend = ->(account, amount) do
      account.entries.create!(name: "Gift", date: prior_start + 2.days, amount: amount, currency: "USD",
                              entryable: Transaction.new(category: category))
    end
    spend.call(accounts(:depository), 100) # shared with the member
    spend.call(accounts(:connected), 300)  # not shared

    result = Assistant::Function::GetBudget.new(users(:family_member)).call("prior_months" => 1)

    gifts = result[:months].first[:categories].find { |line| line[:name] == "Gifts" }
    assert_equal "$100.00", gifts[:actual]
    assert_equal "20.0%", gifts[:percent_spent]
  end

  test "raises on invalid month format" do
    assert_raises(Assistant::Error) do
      @function.call("month" => "not-a-month")
    end
  end

  test "rejects month strings with trailing characters" do
    [ "2026-05-01", "2026-05foo", "may-2026foo" ].each do |raw|
      assert_raises(Assistant::Error, "Expected #{raw.inspect} to be rejected") do
        @function.call("month" => raw)
      end
    end
  end

  test "nests subcategories under their parent" do
    result = @function.call({})
    categories = result[:months].first[:categories]

    food = categories.find { |c| c[:name] == "Food & Drink" }
    assert food, "Food & Drink parent should be present"
    sub_names = food[:subcategories].map { |s| s[:name] }
    assert_includes sub_names, "Restaurants"
  end

  test "category status reflects over_budget helper" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month, user: @user)
    food_bc = budget.budget_categories.find { |bc| bc.category == categories(:food_and_drink) }
    food_bc.update!(budgeted_spending: 100)

    BudgetCategory.any_instance.stubs(:actual_spending).returns(150)

    result = @function.call({})
    food = result[:months].first[:categories].find { |c| c[:name] == "Food & Drink" }
    assert_equal "over_budget", food[:status]
  end

  test "category status is near_limit when spending outside bills fills the line" do
    assert_equal "near_limit", food_status(spent: 95, bills_paid: 0)
  end

  # Bills paid early fill the line without using anything up.
  test "category status is on_track when bills fill the line" do
    assert_equal "on_track", food_status(spent: 95, bills_paid: 95)
  end

  test "suggested_daily_spending omitted on non-current months" do
    target = Date.current.beginning_of_month << 1
    result = @function.call("month" => target.strftime("%Y-%m"))
    past = result[:months].first

    refute past[:is_current]
    past[:categories].each do |cat|
      refute cat.key?(:suggested_daily_spending), "Past months should not include suggested_daily_spending"
      cat[:subcategories].each do |sub|
        refute sub.key?(:suggested_daily_spending), "Past month subcategories should not include suggested_daily_spending"
      end
    end
  end

  test "includes color on parent categories" do
    result = @function.call({})
    result[:months].first[:categories].each do |cat|
      assert cat.key?(:color), "Each parent category should expose a color"
    end
  end

  test "totals expose budget pacing fields" do
    result = @function.call({})
    totals = result[:months].first[:totals]

    %i[budgeted_spending allocated_spending available_to_allocate actual_spending
       available_to_spend percent_of_budget_spent overage_percent].each do |key|
      assert totals.key?(key), "totals should include #{key}"
    end
  end

  private
    def food_status(spent:, bills_paid:)
      budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month, user: @user)
      budget.budget_categories.find { |bc| bc.category == categories(:food_and_drink) }.update!(budgeted_spending: 100)
      BudgetCategory.any_instance.stubs(:actual_spending).returns(spent)
      BudgetCategory.any_instance.stubs(:bills_paid).returns(bills_paid)

      @function.call({})[:months].first[:categories].find { |c| c[:name] == "Food & Drink" }[:status]
    end
end
