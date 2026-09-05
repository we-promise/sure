require "test_helper"

class Assistant::Function::GetCategoryTrendsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    # A name the fixtures do not ship, so existing fixture spending cannot
    # pollute the series under test.
    @category = @family.categories.create!(name: "Dining QA")
    @fn = Assistant::Function::GetCategoryTrends.new(@user)
  end

  def spend(amount, months_ago:, category: @category)
    entry = Entry.create!(
      account: @account,
      name: "Meal",
      date: Date.current.beginning_of_month.advance(months: -months_ago) + 3,
      amount: amount,
      currency: @account.currency,
      entryable: Transaction.new
    )
    entry.entryable.update!(category: category)
    entry
  end

  # The fixture family has more categories than the default limit, so the
  # series under test has to be asked for explicitly.
  def trends(**params)
    @fn.call({ "months" => 6, "limit" => 25 }.merge(params.transform_keys(&:to_s)))
  end

  def dining(result)
    result[:categories].find { |c| c[:category] == "Dining QA" }
  end

  test "has correct name and is not strict" do
    assert_equal "get_category_trends", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "returns one value per month aligned with the month labels" do
    spend(100, months_ago: 2)

    result = trends

    assert_equal 6, result[:months].size
    assert_equal Date.current.strftime("%Y-%m"), result[:months].last
    assert_equal 6, dining(result)[:values].size
  end

  test "detects a category drifting upwards" do
    [ 150, 160, 170, 200, 260, 300 ].each_with_index do |amount, index|
      spend(amount, months_ago: 5 - index)
    end

    row = dining(trends)

    assert_equal "rising", row[:direction]
    assert_operator row[:slope_per_month], :>, 0
    assert_operator row[:second_half_average], :>, row[:first_half_average]
    assert_operator row[:change_pct], :>, 10
  end

  test "detects a category falling" do
    [ 300, 280, 250, 180, 150, 120 ].each_with_index do |amount, index|
      spend(amount, months_ago: 5 - index)
    end

    assert_equal "falling", dining(trends)[:direction]
  end

  test "does not call one exceptional month a trend" do
    [ 100, 100, 100, 100, 100, 600 ].each_with_index do |amount, index|
      spend(amount, months_ago: 5 - index)
    end

    row = dining(trends)

    assert_includes %w[unclear rising], row[:direction]
    assert row[:values].last > row[:values].first,
           "the spike is still visible in the raw values for the model to judge"
  end

  test "reports a steady category as flat" do
    6.times { |i| spend(100, months_ago: i) }

    assert_equal "flat", dining(trends)[:direction]
  end

  test "omits change_pct rather than reporting growth from nothing" do
    spend(200, months_ago: 0)
    spend(200, months_ago: 1)

    row = dining(trends)

    assert_nil row[:change_pct], "a percentage change from zero is not a number to read aloud"
  end

  test "restricts to named categories" do
    other = @family.categories.create!(name: "Groceries QA")
    spend(100, months_ago: 1)
    spend(500, months_ago: 1, category: other)

    result = trends("categories" => [ "dining qa" ])

    assert_equal [ "Dining QA" ], result[:categories].map { |c| c[:category] }
  end

  test "orders by total and flags truncation" do
    other = @family.categories.create!(name: "Groceries QA")
    spend(100, months_ago: 1)
    spend(900, months_ago: 1, category: other)

    result = @fn.call("months" => 6, "limit" => 1)

    assert_equal "Groceries QA", result[:categories].first[:category]
    assert result[:truncated]
  end

  test "clamps the window instead of accepting an unbounded one" do
    result = @fn.call("months" => 999)

    assert_equal IncomeStatement::CategoryTrends::MAX_MONTHS, result[:months].size
  end

  test "supports income as well as spending" do
    result = trends("classification" => "income")

    assert_equal "income", result[:classification]
  end

  # The tool sells itself as "one call instead of thousands of rows", but it used
  # to fire one aggregation per month of the window, so asking for two years cost
  # 24 scans. One grouped query returns the same numbers.
  test "aggregates the whole window in a single query" do
    spend(100, months_ago: 1)

    aggregations = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      aggregations += 1 if payload[:sql].to_s.include?("is_uncategorized_investment")
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      IncomeStatement::CategoryTrends.new(@family, user: @user, months: 12).series
    end

    assert_equal 1, aggregations, "expected one grouped aggregation for a 12-month window, got #{aggregations}"
  end
end
