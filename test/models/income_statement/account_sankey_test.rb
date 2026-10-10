require "test_helper"

class IncomeStatement::AccountSankeyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @card = @family.accounts.create!(name: "Card", currency: "USD", balance: 0, accountable: CreditCard.new)
    @month = Date.new(2024, 2, 1)
    @salary = @family.categories.create!(name: "Salary", color: "#00aa00")
    @shopping = @family.categories.create!(name: "Shopping", color: "#123456")
    @groceries = @family.categories.create!(name: "Groceries", parent: @shopping)
  end

  test "flows run from income categories through each account to expense categories" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 300, @shopping)
    transaction(@card, 200, @groceries)
    result = graph

    assert_equal "net_by_account", result[:basis]
    assert_equal "1000.0", result[:income]
    assert_equal "500.0", result[:spending]
    assert_equal "500.0", result[:net_savings]
    assert_nil node(result, "cash_flow_node")
    assert_equal "account", node(result, "account_#{@checking.id}")[:kind]
    assert_link result, "income_#{@salary.id}", "account_#{@checking.id}", "1000.0"
    assert_link result, "account_#{@checking.id}", "expense_#{@shopping.id}", "300.0"
    assert_link result, "account_#{@card.id}", "expense_#{@shopping.id}", "200.0"
    assert_equal "500.0", node(result, "expense_#{@shopping.id}")[:value], "one category node across accounts"
    assert_link result, "expense_#{@shopping.id}", "expense_sub_#{@groceries.id}", "200.0"
    assert_equal @groceries.filter_value, node(result, "expense_sub_#{@groceries.id}")[:filter_value]
    assert_balanced result
  end

  test "an account taking in more than it spends feeds Surplus, one spending more is fed by Deficit" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 100, @shopping)
    transaction(@card, 250, @shopping)
    result = graph

    assert_link result, "account_#{@checking.id}", "surplus_node", "900.0"
    assert_link result, "deficit_node", "account_#{@card.id}", "250.0"
    assert_equal "900.0", node(result, "surplus_node")[:value]
    assert_equal "250.0", node(result, "deficit_node")[:value]
    assert_balanced result
  end

  test "accounts without income or spending are left out, and an empty period is empty" do
    transaction(@checking, 50, @shopping)
    assert_nil node(graph, "account_#{@card.id}")
    assert_equal({ nodes: [], links: [] }, graph(Date.new(2023, 1, 1)).slice(:nodes, :links))
  end

  test "a category's per-account netting matches the category view" do
    transaction(@checking, 120, @shopping)
    transaction(@checking, -20, @shopping)
    result = graph
    by_category = IncomeStatement::Sankey.new(IncomeStatement.new(@family), period: period).as_json

    assert_equal by_category[:spending], result[:spending]
    assert_equal node(by_category, "expense_#{@shopping.id}")[:value], node(result, "expense_#{@shopping.id}")[:value]
  end

  private
    def transaction(account, amount, category)
      create_transaction(account: account, amount: amount, category: category, date: @month)
    end

    def period(month = @month)
      Period.custom(start_date: month, end_date: month.end_of_month)
    end

    def graph(month = @month)
      IncomeStatement::AccountSankey.new(IncomeStatement.new(@family), period: period(month)).as_json
    end

    def node(graph, id)
      graph[:nodes].find { |node| node[:id] == id }
    end

    def assert_link(graph, source_id, target_id, value)
      ids = graph[:nodes].map { |node| node[:id] }
      link = graph[:links].find { |l| l[:source] == ids.index(source_id) && l[:target] == ids.index(target_id) }
      assert link, "expected a link #{source_id} -> #{target_id}"
      assert_equal value, link[:value]
    end

    # Every account balances, and every node's value is its larger side.
    def assert_balanced(graph)
      graph[:nodes].each_with_index do |node, index|
        incoming, outgoing = %i[target source].map do |end_point|
          graph[:links].select { |link| link[end_point] == index }.sum { |link| link[:value].to_d }
        end
        assert_operator node[:value].to_d, :>, 0
        assert_operator node[:percentage].to_d, :<=, 100
        assert_equal incoming, outgoing, "#{node[:id]} must balance" if node[:kind] == "account"
        assert_equal node[:value].to_d, [ incoming, outgoing ].max, "#{node[:id]} must match its links' capacity"
      end
    end
end
