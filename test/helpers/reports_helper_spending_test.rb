require "test_helper"

class ReportsHelperSpendingTest < ActionView::TestCase
  include ReportsHelper
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    Current.session = users(:empty).sessions.create!
    @account = @family.accounts.create!(name: "Checking", currency: @family.currency, balance: 0, accountable: Depository.new)
    @food = @family.categories.create!(name: "Food")
    @groceries = @family.categories.create!(name: "Groceries", parent: @food)
    @period = Period.custom(start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30))
  end

  test "labels a parent's own spending when it sits beside subcategories" do
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 150, category: @groceries)
    create_transaction(account: @account, date: Date.new(2026, 9, 6), amount: 50, category: @food)

    food = nodes.sole
    direct = food[:children].find { |c| c[:direct] }

    assert_equal "Food (no subcategory)", direct[:name]
    assert_equal "Food › Food (no subcategory): $50.00", direct[:description].first
    assert_equal "No earlier history to compare against", direct[:description].second
  end

  test "describes the change with an interpolated percent, and skips one under 1" do
    12.times { |i| create_transaction(account: @account, date: Date.new(2025, 9, 4) + i.months, amount: 100, category: @groceries) }
    create_transaction(account: @account, date: Date.new(2026, 9, 5), amount: 200, category: @groceries)

    groceries = nodes(history_start: Date.new(2025, 9, 1)).sole[:children].sole

    assert_equal "Groceries", groceries[:name], "a lone subcategory needs no label"
    assert_match(/\A\$\d+\.\d\d more than normal \(\d+%\)\z/, groceries[:description].last)
  end

  private
    def nodes(history_start: @period.start_date)
      comparison = IncomeStatement::SpendingComparison.new(IncomeStatement.new(@family), period: @period, history_start: history_start, as_of: Date.new(2026, 10, 15))
      spending_treemap_nodes(comparison, start_date: @period.start_date, end_date: @period.end_date)
    end
end
