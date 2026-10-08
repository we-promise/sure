require "test_helper"

class IncomeStatement::SpendingComparisonTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new)

    @salary = @family.categories.create!(name: "Salary")
    @food = @family.categories.create!(name: "Food")
    @groceries = @family.categories.create!(name: "Groceries", parent: @food)
    @travel = @family.categories.create!(name: "Travel")

    @period = Period.custom(start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30))
    @baseline_start = @period.start_date - 1.year
  end

  test "history starts at the first transaction that counts, not an excluded one or a valuation" do
    create_transaction(account: @account, date: Date.new(2024, 1, 10), amount: 40, category: @food, excluded: true)
    @account.entries.create!(date: Date.new(2023, 6, 1), amount: 5000, currency: @family.currency, name: "Opening balance",
                             entryable: Valuation.new(kind: "opening_anchor"))
    create_transaction(account: @account, date: Date.new(2026, 3, 2), amount: 25, category: @food)

    assert_equal Date.new(2026, 3, 2), IncomeStatement::SpendingComparison.history_start(IncomeStatement.new(@family))
  end

  test "spending is net of refunds, and spending on the parent gets its own row" do
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 300, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 9, 9), amount: -100, category: @groceries) # refund
    create_transaction(account: @account, date: Date.new(2026, 9, 12), amount: 50, category: @food)
    create_transaction(account: @account, date: Date.new(2026, 9, 15), amount: -2000, category: @salary)

    food = comparison.rows.find { |r| r.category == @food }

    assert_equal 250, food.total
    assert_equal({ "Groceries" => 200, "Food" => 50 }, food.subcategories.to_h { |s| [ s.category.name, s.total ] })
    assert_not comparison.rows.any? { |r| r.category == @salary }, "income categories are not spending"
  end

  test "normal is the year before the period, scaled to the period's length" do
    12.times { |i| create_transaction(account: @account, date: @baseline_start + i.months + 3.days, amount: 100, category: @groceries) }
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 300, category: @groceries)

    food = comparison(history_start: @baseline_start).rows.find { |r| r.category == @food }
    expected_normal = 1200 * 30 / 365r

    assert_in_delta expected_normal, food.normal, 0.01
    assert_in_delta 300 - expected_normal, food.change, 0.01
    assert_in_delta (300 - expected_normal) / expected_normal, food.ratio, 0.0001
    assert_equal Date.new(2025, 9, 1), comparison(history_start: @baseline_start).baseline_period.start_date
  end

  test "a short history shortens the baseline instead of diluting normal" do
    3.times { |i| create_transaction(account: @account, date: Date.new(2026, 6, 10) + i.months, amount: 90, category: @travel) }
    create_transaction(account: @account, date: Date.new(2026, 9, 10), amount: 90, category: @travel)

    result = comparison(history_start: Date.new(2026, 6, 1))
    travel = result.rows.find { |r| r.category == @travel }

    assert_equal Date.new(2026, 6, 1), result.baseline_period.start_date
    assert_in_delta 270 * 30 / 92r, travel.normal, 0.01
  end

  test "without enough earlier history there is no normal" do
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 300, category: @groceries)

    result = comparison(history_start: Date.new(2026, 8, 20))

    assert_not result.comparable?
    assert_nil result.rows.first.normal
    assert_nil result.rows.first.ratio
    assert_nil result.normal_total
  end

  test "a category with spending only in the baseline shows as spending nothing now" do
    create_transaction(account: @account, date: Date.new(2026, 3, 1), amount: 600, category: @travel)
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 300, category: @groceries)

    travel = comparison(history_start: @baseline_start).rows.find { |r| r.category == @travel }

    assert_equal 0, travel.total
    assert travel.normal.positive?
    assert travel.change.negative?
  end

  test "a subcategory refunded below zero doesn't make the others overstate the parent" do
    bakery = @family.categories.create!(name: "Bakery", parent: @food)
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 100, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 9, 6), amount: -60, category: bakery) # refund only

    food = comparison.rows.find { |r| r.category == @food }

    assert_equal 40, food.total
    assert_equal [ [ @food, 40 ] ], food.subcategories.map { |s| [ s.category, s.total ] }
  end

  test "uncategorized spending is its own row" do
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 40)

    assert comparison.rows.any? { |r| r.category.uncategorized? && r.total == 40 }
  end

  private
    def comparison(history_start: @period.start_date)
      IncomeStatement::SpendingComparison.new(IncomeStatement.new(@family), period: @period, history_start: history_start)
    end
end
