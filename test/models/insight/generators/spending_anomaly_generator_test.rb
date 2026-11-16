require "test_helper"

class Insight::Generators::SpendingAnomalyGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include SqlQueryCapture

  setup do
    @family = families(:dylan_family)
    @category = @family.categories.create!(name: "Pace Test Cat", color: "#101010", lucide_icon: "circle")
  end

  # Anchor two months back so the relative-date fixture entries (always in the
  # real current month) can't leak into the baseline or current periods. Day 10
  # gives 10 elapsed days, comfortably past MIN_ELAPSED_DAYS. Tests that need a
  # different point in the month set @anchor_day before the first call.
  def anchor
    @anchor ||= (Date.current - 2.months).change(day: @anchor_day || 10)
  end

  def baseline_months
    (1..3).map { |i| month_start(i) }
  end

  def current_month
    anchor.beginning_of_month
  end

  def month_start(offset)
    (anchor.beginning_of_month - offset.months).beginning_of_month
  end

  def spend(month, total, day: 3)
    create_transaction(category: @category, amount: total, date: month.change(day: day), name: "test #{month} #{day}")
  end

  def generate
    Insight::Generators::SpendingAnomalyGenerator.new(@family).generate
  end

  # $1,000 spent by day 10 against a $3,000 monthly baseline is exactly on pace:
  # projected over a 28-31 day month it lands within 7% of the baseline, well
  # inside DEVIATION_THRESHOLD_PCT. Without the pace factor the raw $1,000 reads
  # as 67% below baseline and produces a high-priority false alarm.
  test "does not flag a category that is on pace for its baseline" do
    travel_to anchor do
      3.times { |i| spend(month_start(i + 1), 3_000) }
      spend(anchor.beginning_of_month, 1_000)

      assert_empty generate
    end
  end

  # The same $1,000 by day 10, but against a $1,000 monthly baseline, projects to
  # roughly triple the usual month and must be flagged. Without the pace factor
  # the raw total matches the baseline exactly and nothing is reported.
  test "flags a category running well ahead of its baseline" do
    travel_to anchor do
      3.times { |i| spend(month_start(i + 1), 1_000) }
      spend(anchor.beginning_of_month, 1_000)

      insights = generate

      assert_equal 1, insights.size
      assert_equal "above", insights.first.metadata[:direction]
      assert_equal "high", insights.first.priority
    end
  end

  # Fixed charges that landed early (a gym fee and a medical plan, the same
  # every month) are already the whole month. Projecting them by pace doubled
  # them on day 15 and reported the category as trending up about 100%.
  test "does not project bills already paid this month" do
    @anchor_day = 15
    gym = create_bill(category: @category, amount: 47.98, name: "Gym", day: 3)
    medical = create_bill(category: @category, amount: 5, name: "Medical plan", day: 5)

    travel_to anchor do
      [ *baseline_months, current_month ].each do |month|
        pay_bill(gym, date: month.change(day: 3))
        pay_bill(medical, date: month.change(day: 5))
      end

      assert_empty generate
    end
  end

  # A bill still due this month is spending the month will have: it is added
  # at face value, so the projection, and the deviation, reflect it. Left out,
  # the category would read 52% below its average instead of 29%. The bill
  # sits in a subcategory and counts under its parent, as its payments do.
  test "counts a bill still due this month at face value" do
    insurance_category = @family.categories.create!(name: "Pace Test Insurance", parent: @category)
    rent = create_bill(category: @category, amount: 1_000, name: "Rent", day: 3)
    insurance = create_bill(category: insurance_category, amount: 500, name: "Insurance", day: 20)

    travel_to anchor do
      baseline_months.each do |month|
        pay_bill(rent, date: month.change(day: 3))
        pay_bill(insurance, date: month.change(day: 20))
        spend(month, 600, day: 12)
      end
      pay_bill(rent, date: current_month.change(day: 3))
      expect_bill(insurance, due_on: current_month.change(day: 20))

      insights = generate

      assert_equal 1, insights.size
      assert_equal "below", insights.first.metadata[:direction]
      assert_equal "medium", insights.first.priority
      assert_equal Money.new(1_500, "USD").format, insights.first.facts[:projected_spend]
    end
  end

  # Bills do not hide the rest of the category: spending outside them that is
  # running ahead of its usual pace is still reported.
  test "flags unplanned spending running ahead in a category with bills" do
    rent = create_bill(category: @category, amount: 1_000, name: "Rent", day: 3)

    travel_to anchor do
      baseline_months.each do |month|
        pay_bill(rent, date: month.change(day: 3))
        spend(month, 300, day: 12)
      end
      pay_bill(rent, date: current_month.change(day: 3))
      spend(current_month, 600, day: 5)

      insights = generate

      assert_equal 1, insights.size
      assert_equal "above", insights.first.metadata[:direction]
    end
  end

  # An annual premium paid this month makes the month dearer than the last
  # three, but it was planned: the spending outside bills is as usual, so
  # there is no trend to report.
  test "does not flag a month made dearer only by a bill" do
    @anchor_day = 15
    rent = create_bill(category: @category, amount: 1_000, name: "Rent", day: 3)
    premium = create_bill(category: @category, amount: 800, name: "Home insurance", day: 10)

    travel_to anchor do
      baseline_months.each do |month|
        pay_bill(rent, date: month.change(day: 3))
        spend(month, 100, day: 12)
      end
      pay_bill(rent, date: current_month.change(day: 3))
      pay_bill(premium, date: current_month.change(day: 10))
      spend(current_month, 50, day: 5)

      assert_empty generate
    end
  end

  # The mirror case: the same premium paid in one of the baseline months lifts
  # the average, and a normal month must not read as spending falling.
  test "does not flag a month made cheaper only by a bill in the baseline" do
    @anchor_day = 15
    rent = create_bill(category: @category, amount: 1_000, name: "Rent", day: 3)
    premium = create_bill(category: @category, amount: 2_400, name: "Home insurance", day: 10)

    travel_to anchor do
      baseline_months.each do |month|
        pay_bill(rent, date: month.change(day: 3))
        spend(month, 100, day: 12)
      end
      pay_bill(premium, date: month_start(2).change(day: 10))
      pay_bill(rent, date: current_month.change(day: 3))
      spend(current_month, 50, day: 5)

      assert_empty generate
    end
  end

  # Money saved up in a rollover envelope is there to be spent in a lump: a
  # holiday paid from it is the plan, not a trend.
  test "does not flag a rollover category spending within its envelope" do
    @anchor_day = 15
    budget_line(rollover_enabled: true, budgeted_spending: 100, rolled_over_amount: 900)

    travel_to anchor do
      baseline_months.each { |month| spend(month, 100) }
      spend(current_month, 600, day: 5)

      assert_empty generate
    end
  end

  # The feed is the whole family's, so only the household budget may hold
  # back an anomaly: one member's personal envelope says nothing about what
  # the others spent.
  test "ignores a personal budget's rollover envelope" do
    @anchor_day = 15
    budget_line(user: users(:family_admin), rollover_enabled: true, budgeted_spending: 100, rolled_over_amount: 900)

    travel_to anchor do
      baseline_months.each { |month| spend(month, 100) }
      spend(current_month, 600, day: 5)

      assert_equal [ "above" ], generate.map { |insight| insight.metadata[:direction] }
    end
  end

  # The carry often sits on a ring-fenced subcategory (Insurance under Home)
  # while the parent has none. Spending from that envelope is still planned.
  test "does not flag spending from a subcategory's rollover envelope" do
    @anchor_day = 15
    insurance = @family.categories.create!(name: "Pace Test Insurance", parent: @category)
    budget_line(budgeted_spending: 200)
    budget_line(category: insurance, rollover_enabled: true, budgeted_spending: 100, rolled_over_amount: 900)

    travel_to anchor do
      baseline_months.each { |month| spend(month, 100) }
      create_transaction(category: insurance, amount: 600, date: current_month.change(day: 5), name: "Insurance premium")

      assert_empty generate
    end
  end

  # A bill paid from a rollover envelope is already planned as a bill. Counted
  # again as envelope spend, the 400 premium would hide the 600 spent
  # elsewhere in the category.
  test "counts a bill paid from a rollover envelope once" do
    @anchor_day = 15
    insurance = @family.categories.create!(name: "Pace Test Insurance", parent: @category)
    premium = create_bill(category: insurance, amount: 400, name: "Insurance", day: 3)
    budget_line(budgeted_spending: 200)
    budget_line(category: insurance, rollover_enabled: true, budgeted_spending: 100, rolled_over_amount: 900)

    travel_to anchor do
      baseline_months.each do |month|
        pay_bill(premium, date: month.change(day: 3))
        spend(month, 300, day: 12)
      end
      pay_bill(premium, date: current_month.change(day: 3))
      spend(current_month, 600, day: 5)

      assert_equal [ "above" ], generate.map { |insight| insight.metadata[:direction] }
    end
  end

  test "flags a rollover category that has outspent its envelope" do
    @anchor_day = 15
    budget_line(rollover_enabled: true, budgeted_spending: 100, rolled_over_amount: 400)

    travel_to anchor do
      baseline_months.each { |month| spend(month, 100) }
      spend(current_month, 600, day: 5)

      assert_equal [ "above" ], generate.map { |insight| insight.metadata[:direction] }
    end
  end

  test "flags a category without rollover even when its budget covers the spend" do
    @anchor_day = 15
    budget_line(rollover_enabled: false, budgeted_spending: 1_000)

    travel_to anchor do
      baseline_months.each { |month| spend(month, 100) }
      spend(current_month, 600, day: 5)

      assert_equal [ "above" ], generate.map { |insight| insight.metadata[:direction] }
    end
  end

  # The generator runs nightly for every family, so bills are read in bulk:
  # more of them must not mean more queries.
  test "reads bills with a fixed number of queries" do
    categories = [ @category ] + 2.times.map do |i|
      @family.categories.create!(name: "Pace Test Cat #{i}", color: "#101010", lucide_icon: "circle")
    end

    travel_to anchor do
      bills = categories.map { |category| create_bill(category: category, amount: 100, name: category.name, day: 3) }
      [ *baseline_months, current_month ].each { |month| pay_bill(bills.first, date: month.change(day: 3)) }
      expect_bill(bills.first, due_on: current_month.change(day: 25))
      generate # loads the account-type ids IncomeStatement keeps per process
      with_one_bill = uncached_query_count { generate }

      bills.drop(1).each do |bill|
        [ *baseline_months, current_month ].each { |month| pay_bill(bill, date: month.change(day: 3)) }
        expect_bill(bill, due_on: current_month.change(day: 25))
      end

      assert_equal with_one_bill, uncached_query_count { generate }
    end
  end

  private
    # IncomeStatement caches its totals, so each count starts cold.
    def uncached_query_count(&block)
      Rails.cache.clear
      ActiveRecord::Base.uncached { capture_sql_queries(&block).size }
    end

    def budget_line(category: @category, user: nil, **attributes)
      budget = @family.budgets.find_or_create_by!(start_date: current_month, end_date: current_month.end_of_month, user: user) do |b|
        b.budgeted_spending = 2_000
        b.expected_income = 3_000
        b.currency = "USD"
      end
      budget.budget_categories.create!(category: category, currency: "USD", **attributes)
    end
end
