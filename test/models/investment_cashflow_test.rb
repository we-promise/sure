require "test_helper"

class InvestmentCashflowTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create!(name: "Checking", accountable: Depository.new, balance: 10_000, currency: "USD", status: "active")
    @investment = @family.accounts.create!(name: "Brokerage", accountable: Investment.new, balance: 10_000, currency: "USD", status: "active")
    @category = @family.categories.create!(name: "Investment allocation")
    @month = Date.current.beginning_of_month.prev_month
    @period = Period.custom(start_date: @month, end_date: @month.end_of_month)
  end

  test "investment budgets retain allocation usage statistics and rollover without increasing consumption" do
    [ [ 100, 5000 ], [ 6000, 1000 ], [ 200, 9000 ] ].each_with_index do |(expense, invested), offset|
      date = @month - offset.months
      create_transaction(account: @checking, date: date, amount: expense)
      contribution(invested, date: date)
    end
    budget = @family.budgets.create!(start_date: @month, end_date: @month.end_of_month, currency: "USD", budgeted_spending: 5100)
    category = budget.budget_categories.create!(category: @category, budgeted_spending: 5000, currency: "USD", rollover_enabled: true)
    following = @family.budgets.create!(start_date: @month.next_month, end_date: @month.next_month.end_of_month, currency: "USD", budgeted_spending: 5100)
    next_category = following.budget_categories.create!(category: @category, budgeted_spending: 5000, currency: "USD", rollover_enabled: true)

    assert_equal 100, statement.expense_totals(period: @period).total
    assert_equal 5000, statement.investment_contribution_totals(period: @period).total
    assert_equal 5100, budget.actual_spending
    assert_equal 7000, budget.estimated_spending, "median must be computed after combining each month's cash outflows"
    assert_equal 5000, budget.budget_category_actual_spending(category)
    assert_equal 5000, budget.category_median_monthly_expense(@category)
    assert_equal 5000, budget.category_avg_monthly_expense(@category)
    Budget::RolloverCalculator.new(family: @family, user: nil).recompute!
    assert_equal 0, next_category.reload.rolled_over_amount
  end

  test "cash warnings still account for money invested out of checking" do
    @checking.update!(balance: 1000)
    contribution(800)
    assert_equal 0, statement.median_expense
    warnings = Insight::Generators::CashFlowWarningGenerator.new(@family).generate
    assert_equal 1, warnings.size
    assert_equal "cash_flow_warning", warnings.first.insight_type
  end

  test "provider resync cannot count the brokerage leg a second time" do
    pair = contribution(2000)
    incoming = pair.inflow_transaction.entry
    incoming.update!(external_id: "brokerage-deposit", source: "snaptrade")
    Account::ProviderImportAdapter.new(@investment).import_transaction(
      external_id: incoming.external_id, source: "snaptrade", amount: -2000,
      currency: "USD", date: @month, name: "Brokerage contribution", investment_activity_label: "Contribution"
    )
    assert_equal "funds_movement", incoming.reload.transaction.kind
    assert_equal 2000, statement.investment_contribution_totals(period: @period).total
    assert_equal 0, statement.expense_totals(period: @period).total
  end

  test "legacy duplicated contribution and loan kinds count only the matched outflow" do
    pair = contribution(2000)
    pair.inflow_transaction.update!(kind: "investment_contribution")
    assert_equal 2000, statement.investment_contribution_totals(period: @period).total
    pair.outflow_transaction.update!(kind: "loan_payment")
    pair.inflow_transaction.update!(kind: "loan_payment")
    assert_equal 2000, statement.expense_totals(period: @period).total
  end

  test "a matched pair does not contribute again when only its brokerage leg is selected" do
    pair = contribution(2000)
    pair.inflow_transaction.update!(kind: "investment_contribution")
    assert_equal 0, statement.totals_for(@period, account_ids: [ @investment.id ]).investment_contribution_money.amount
    assert_equal 2000, statement.totals_for(@period, account_ids: [ @checking.id ]).investment_contribution_money.amount
  end

  test "an explicit income correction survives provider sync and automatic transfer detection" do
    [ "Contribution", "Transfer" ].each_with_index do |label, index|
      amount = 3000 + index
      adapter = Account::ProviderImportAdapter.new(@investment)
      deposit = adapter.import_transaction(external_id: label, source: "snaptrade", amount: -amount,
        currency: "USD", date: @month, name: "Payroll #{label}", investment_activity_label: label)
      salary = @family.categories.create!(name: "Salary #{label}")
      deposit.transaction.update!(category: salary)
      assert deposit.transaction.correctable_as_income?
      deposit.transaction.correct_as_income!
      assert deposit.reload.user_modified?
      assert deposit.transaction.locked?(:kind)
      adapter.import_transaction(external_id: label, source: "snaptrade", amount: -amount,
        currency: "USD", date: @month, name: "Provider payroll", investment_activity_label: label)
      create_transaction(account: @checking, amount: amount, date: @month)
      @family.auto_match_transfers!
      deposit.reload
      assert_equal "standard", deposit.transaction.kind
      assert_nil deposit.transaction.investment_activity_label
      assert_nil deposit.transaction.transfer
      assert_equal salary, deposit.transaction.category
    end
    assert_equal 6001, statement.income_totals(period: @period).total
  end

  test "correction cannot break a matched pair or reclassify an outflow" do
    pair = contribution(2000)
    refute pair.inflow_transaction.correctable_as_income?
    assert_raises(ActiveRecord::RecordInvalid) { pair.inflow_transaction.correct_as_income! }
    outflow = create_transaction(account: @investment, amount: 2000, kind: "investment_contribution")
    refute outflow.transaction.correctable_as_income?
  end

  test "invested Sankey flow balances even when funded from prior savings" do
    contribution(2000)
    graph = IncomeStatement::Sankey.new(statement, period: @period).as_json
    assert_equal "2000.0", graph[:invested]
    assert_equal "0.0", graph[:spending]
    assert_equal "0.0", graph[:net_savings]
    center = graph[:nodes].index { |node| node[:id] == "cash_flow_node" }
    inflow = graph[:links].select { |link| link[:target] == center }.sum { |link| link[:value].to_d }
    outflow = graph[:links].select { |link| link[:source] == center }.sum { |link| link[:value].to_d }
    assert_equal 2000, inflow
    assert_equal inflow, outflow
  end

  test "investment to investment matches are funds movements" do
    other = @family.accounts.create!(name: "Second brokerage", accountable: Crypto.new, balance: 0, currency: "USD", status: "active")
    create_transaction(account: @investment, amount: 500, date: @month)
    create_transaction(account: other, amount: -500, date: @month)
    @family.auto_match_transfers!
    assert_equal [ "funds_movement" ], @family.transactions.distinct.pluck(:kind)
    assert_equal 0, statement.investment_contribution_totals(period: @period).total
  end

  private
    def statement
      IncomeStatement.new(@family)
    end

    def contribution(amount, date: @month)
      outflow = create_transaction(account: @checking, amount: amount, date: date, category: @category, kind: "investment_contribution")
      inflow = create_transaction(account: @investment, amount: -amount, date: date, category: @category, kind: "funds_movement")
      Transfer.create!(outflow_transaction: outflow.transaction, inflow_transaction: inflow.transaction, status: "confirmed")
    end
end
