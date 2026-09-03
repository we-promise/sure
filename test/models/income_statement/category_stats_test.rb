require "test_helper"

# See IncomeStatement::FamilyStatsTest for the design contract — this is the
# same behavior, scoped per category instead of family-wide.
class IncomeStatement::CategoryStatsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @groceries = @family.categories.create!(name: "Groceries")
    @checking  = @family.accounts.create!(
      name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    )
  end

  test "a category-period where refunds exceed expenses is reported as income for that category" do
    # January: a normal $150 Groceries expense, no refund
    create_transaction(account: @checking, amount: 150, category: @groceries, date: Date.new(2026, 1, 15))

    # February: a $70 Groceries refund with nothing to offset it that period
    create_transaction(account: @checking, amount: -70, refund: true, category: @groceries, date: Date.new(2026, 2, 15))

    stats = IncomeStatement::CategoryStats.new(@family, interval: "month").call
    groceries_rows = stats.select { |s| s.category_id == @groceries.id }
    expense = groceries_rows.find { |s| s.classification == "expense" }
    income  = groceries_rows.find { |s| s.classification == "income" }

    assert_equal 150, expense.median.to_i
    assert_equal 150, expense.avg.to_i
    assert_equal 70, income.median.to_i
    assert_equal 70, income.avg.to_i
  end

  test "combines reclassified refunds with income in the same category-period" do
    create_transaction(account: @checking, amount: -3000, category: @groceries, date: Date.new(2026, 2, 15))
    create_transaction(account: @checking, amount: -70, refund: true, category: @groceries, date: Date.new(2026, 2, 20))

    income = IncomeStatement::CategoryStats.new(@family, interval: "month").call
      .find { |stat| stat.category_id == @groceries.id && stat.classification == "income" }

    assert_equal 3070, income.median.to_i
    assert_equal 3070, income.avg.to_i
  end
end
