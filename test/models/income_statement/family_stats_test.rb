require "test_helper"

# Tests that verify IncomeStatement::FamilyStats handles refunds correctly.
#
# Design contract under test:
#   - A period's expense total nets refunds against expenses (via
#     IncomeStatement::ClassificationSql.signed_amount), which can make the
#     period's signed total go negative if refunds exceed expenses.
#   - Rather than ABS-ing that distortion back into "expense", the query
#     re-labels the period "income" before computing median/avg — mirroring
#     IncomeStatement::Totals#call's Ruby-side flip, but done in SQL so
#     FamilyStats and CategoryStats can share it.
class IncomeStatement::FamilyStatsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @groceries = @family.categories.create!(name: "Groceries")
    @checking  = @family.accounts.create!(
      name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    )
  end

  test "a period where refunds exceed expenses is reported as income, not inflated expense" do
    # January: a normal $150 expense, no refund
    create_transaction(account: @checking, amount: 150, category: @groceries, date: Date.new(2026, 1, 15))

    # February: a $70 refund with nothing to offset it that period
    create_transaction(account: @checking, amount: -70, refund: true, category: @groceries, date: Date.new(2026, 2, 15))

    stats = IncomeStatement::FamilyStats.new(@family, interval: "month").call
    expense = stats.find { |s| s.classification == "expense" }
    income  = stats.find { |s| s.classification == "income" }

    assert_equal 150, expense.median.to_i,
      "the only real expense period ($150) should drive the expense median, not an average blended with the refund period"
    assert_equal 150, expense.avg.to_i

    assert_equal 70, income.median.to_i,
      "the over-refund period ($70 net inflow) should be counted as income, not silently folded into expense stats"
    assert_equal 70, income.avg.to_i
  end

  test "matches the pre-refund behavior when no refunds are present" do
    create_transaction(account: @checking, amount: 150, category: @groceries, date: Date.new(2026, 1, 15))
    create_transaction(account: @checking, amount: 200, category: @groceries, date: Date.new(2026, 2, 15))
    create_transaction(account: @checking, amount: -2000, date: Date.new(2026, 3, 15))

    stats = IncomeStatement::FamilyStats.new(@family, interval: "month").call
    expense = stats.find { |s| s.classification == "expense" }
    income  = stats.find { |s| s.classification == "income" }

    assert_equal 175, expense.median.to_i
    assert_equal 175, expense.avg.to_i
    assert_equal 2000, income.median.to_i
    assert_equal 2000, income.avg.to_i
  end
end
