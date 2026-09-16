require "test_helper"

class IncomeStatement::CashFlowGraphTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @category = @family.categories.create!(name: "Groceries", color: "#123456")
    @period = Period.custom(start_date: Date.new(2024, 2, 1), end_date: Date.new(2024, 2, 29))
  end

  test "reports investment contributions and debt principal alongside the sankey graph" do
    create_transaction(account: @account, amount: -2500, date: @period.start_date) # income
    create_transaction(account: @account, amount: 1000, date: @period.start_date, category: @category) # consumer spending, own category so Sankey doesn't net it against the uncategorized income
    create_transaction(account: @account, amount: 500, date: @period.start_date, kind: "investment_contribution")
    create_transaction(account: @account, amount: 250, date: @period.start_date, kind: "loan_payment")

    result = graph

    assert_equal "1000.0", result.dig(:sankey, :spending)
    assert_equal "500.0", result[:investment_contributions]
    assert_equal "250.0", result[:debt_principal_payments]
  end

  test "defaults to zero when there is no non-operating activity" do
    create_transaction(account: @account, amount: 100, date: @period.start_date)

    result = graph

    assert_equal "0.0", result[:investment_contributions]
    assert_equal "0.0", result[:debt_principal_payments]
  end

  private
    def graph
      statement = IncomeStatement.new(@family)
      IncomeStatement::CashFlowGraph.new(statement, period: @period).as_json
    end
end
