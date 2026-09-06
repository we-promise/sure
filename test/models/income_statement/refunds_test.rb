require "test_helper"

class IncomeStatement::RefundsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 5000, accountable: Depository.new)
    @category = @family.categories.create!(name: "Clothing")
    @period = Period.current_month
    create_transaction(account: @account, amount: -3000)
  end

  test "refunds reduce category spending and never increase salary income" do
    create_transaction(account: @account, amount: 1000, category: @category)
    create_transaction(account: @account, amount: -800, category: @category, kind: "refund")
    statement = IncomeStatement.new(@family)

    assert_equal 3000, statement.income_totals(period: @period).total
    assert_equal 200, statement.expense_totals(period: @period).total
    assert_equal 800, statement.refund_totals(period: @period).total
    assert_equal 200, statement.daily_expense_series(period: @period).sum(&:total)
    assert_equal 200, statement.net_category_totals(period: @period).total_net_expense
  end

  test "refunds in later months remain negative spending rather than income" do
    create_transaction(account: @account, amount: 1000, category: @category, date: @period.start_date - 1.day)
    create_transaction(account: @account, amount: -800, category: @category, kind: "refund")
    statement = IncomeStatement.new(@family)

    assert_equal 3000, statement.income_totals(period: @period).total
    assert_equal(-800, statement.expense_totals(period: @period).total)
    assert_equal(-800, statement.net_category_totals(period: @period).total_net_expense)
    assert_equal(-800, statement.daily_expense_series(period: @period).sum(&:total))
  end

  test "search income filter excludes refunds and combined filters retain them once" do
    refund = create_transaction(account: @account, amount: -800, category: @category, kind: "refund")
    create_transaction(account: @account, amount: 1000, category: @category)
    search = Transaction::Search.new(@family)
    assert_equal Money.new(3000, "USD"), search.totals.income_money
    assert_equal Money.new(200, "USD"), search.totals.expense_money
    assert_equal Money.new(800, "USD"), search.totals.refund_money
    assert_not_includes Transaction::Search.new(@family, filters: { types: [ "income" ] }).transactions_scope, refund.transaction
    assert_equal [ refund.transaction ], Transaction::Search.new(@family, filters: { types: [ "refund" ] }).transactions_scope.to_a
    assert_equal 3, Transaction::Search.new(@family, filters: { types: %w[income expense refund] }).transactions_scope.count
  end

  test "mixed ordinary credits and marked refunds never move the refund to income" do
    create_transaction(account: @account, amount: 100, category: @category)
    create_transaction(account: @account, amount: -80, category: @category, kind: "refund")
    create_transaction(account: @account, amount: -30, category: @category)
    net = IncomeStatement.new(@family).net_category_totals(period: @period)
    assert_equal(-10, net.total_net_expense)
    assert_equal 3000, net.total_net_income
  end

  test "refund only budget retains credit with a zero width spending bar" do
    create_transaction(account: @account, amount: -800, category: @category, kind: "refund")
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    budget.sync_budget_categories
    category = budget.budget_categories.find_by!(category: @category)
    assert_equal(-800, category.actual_spending)
    assert_equal 0, category.bar_width_percent
    assert_not category.near_limit?
  end

  test "pending refunds do not reduce posted spending" do
    refund = create_transaction(account: @account, amount: -800, kind: "refund")
    refund.transaction.update!(extra: { "plaid" => { "pending" => true } })
    statement = IncomeStatement.new(@family)
    assert_equal 0, statement.expense_totals(period: @period).total
    assert_equal 0, statement.refund_totals(period: @period).total
  end
end
