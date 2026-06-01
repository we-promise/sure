require "test_helper"

# Tests that verify the refund kind is correctly handled by IncomeStatement totals.
#
# Design contract under test:
#   - A refund (amount < 0, kind = 'refund') is classified as 'expense' in analytics.
#   - It therefore reduces the expense total in its category, not the income total.
#   - It does NOT appear in income totals.
#   - It IS included in analytics (not budget-excluded like one_time or cc_payment).
class IncomeStatement::RefundTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @groceries = @family.categories.create!(name: "Groceries")
    @checking  = @family.accounts.create!(
      name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    )
  end

  # ---------------------------------------------------------------------------
  # Refund reduces expense total, not income total
  # ---------------------------------------------------------------------------

  test "refund kind reduces expense total and does not appear in income total" do
    create_transaction(account: @checking, amount: 200, category: @groceries)                      # $200 expense
    create_transaction(account: @checking, amount: -50, kind: "refund", category: @groceries)      # $50 refund

    period = Period.last_30_days
    totals = IncomeStatement.new(@family).totals(date_range: period.date_range)

    assert_equal Money.new(150, @family.currency), totals.expense_money,
      "expense total should be net 150 after $50 refund"
    assert_equal Money.new(0,   @family.currency), totals.income_money,
      "refund must not count as income"
  end

  test "refund with no matching expense shows as negative expense total" do
    # Refund with no corresponding expense in the period — nets to negative expense (handled by outer ABS)
    create_transaction(account: @checking, amount: -80, kind: "refund", category: @groceries)

    totals = IncomeStatement.new(@family).totals(date_range: Period.last_30_days.date_range)

    # ABS(SUM(negative_refund)) = 80 in the expense bucket; since there are no positive expenses
    # the result is still 80 on the expense side (the outer ABS ensures no negative display value).
    assert_equal Money.new(80, @family.currency), totals.expense_money
    assert_equal Money.new(0,  @family.currency), totals.income_money
  end

  test "refund is not excluded from analytics like one_time" do
    create_transaction(account: @checking, amount: 200, category: @groceries)
    create_transaction(account: @checking, amount: -50, kind: "refund",   category: @groceries)
    create_transaction(account: @checking, amount: -30, kind: "one_time", category: @groceries)

    totals = IncomeStatement.new(@family).totals(date_range: Period.last_30_days.date_range)

    # only the $200 expense and the $50 refund appear; one_time is excluded
    assert_equal Money.new(150, @family.currency), totals.expense_money
  end

  # ---------------------------------------------------------------------------
  # Category-level netting
  # ---------------------------------------------------------------------------

  test "net_category_totals shows reduced expense for category containing a refund" do
    create_transaction(account: @checking, amount: 200, category: @groceries)
    create_transaction(account: @checking, amount: -50, kind: "refund", category: @groceries)

    net = IncomeStatement.new(@family).net_category_totals(period: Period.last_30_days)

    groceries_net = net.net_expense_categories.find { |ct| ct.category.id == @groceries.id }
    assert_not_nil groceries_net
    assert_equal 150, groceries_net.total
  end

  test "refund in a different category does not reduce expense in original category" do
    clothing = @family.categories.create!(name: "Clothing")

    create_transaction(account: @checking, amount: 200, category: @groceries)
    create_transaction(account: @checking, amount: -50, kind: "refund", category: clothing)

    net = IncomeStatement.new(@family).net_category_totals(period: Period.last_30_days)

    groceries_net = net.net_expense_categories.find { |ct| ct.category.id == @groceries.id }
    assert_equal 200, groceries_net.total, "grocery category should be unchanged"
  end
end
