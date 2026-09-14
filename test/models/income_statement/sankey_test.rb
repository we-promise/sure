require "test_helper"

class IncomeStatement::SankeyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @month = Date.new(2024, 2, 1)
    @parent = @family.categories.create!(name: "Shopping", color: "#123456")
    @child = @family.categories.create!(name: "Rebates", parent: @parent)
  end

  test "opposite direction children are not double counted in parent totals" do
    transaction(100, @parent)
    transaction(-30, @child)
    result = graph
    assert_equal "100.0", result[:spending]
    assert_equal "30.0", result[:income]
    assert_equal "-70.0", result[:net_savings]
    assert_equal "100.0", node(result, "expense_#{@parent.id}")[:value]
    assert_equal "30.0", node(result, "income_#{@parent.id}")[:value]
    assert_equal @child.filter_value, node(result, "income_sub_#{@child.id}")[:filter_value]
    assert_equal "70.0", node(result, "deficit_node")[:value]
    assert_balanced(result)
  end

  test "zero net parent retains both directions and same-category refunds net once" do
    transaction(150, @parent)
    transaction(-50, @parent)
    transaction(-100, @child)
    result = graph
    assert_equal "100.0", result[:income]
    assert_equal "100.0", result[:spending]
    assert_equal "0.0", result[:net_savings]
    assert_balanced(result)
  end

  test "same direction children share parent capacity without duplicating totals" do
    transaction(10, @parent)
    transaction(20, @child)
    result = graph
    assert_equal "30.0", result[:spending]
    assert_equal "30.0", node(result, "expense_#{@parent.id}")[:value]
    assert_equal "20.0", node(result, "expense_sub_#{@child.id}")[:value]
    assert_balanced(result)
  end

  test "preserves FX precision, reporting eligibility and surplus" do
    eur = @family.accounts.create!(name: "EUR", currency: "EUR", balance: 0, accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @month, rate: "1.2345")
    create_transaction(account: eur, currency: "EUR", amount: 10, date: @month, category: @child)
    transaction(-100, @parent)
    create_transaction(account: @account, amount: 900, date: @month, excluded: true)
    create_transaction(account: @account, amount: 800, date: @month, kind: "cc_payment")
    pending = create_transaction(account: @account, amount: 700, date: @month)
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })
    create_transaction(account: accounts(:depository), amount: 600, date: @month)
    result = graph
    assert_equal "12.345", result[:spending]
    assert_equal "87.655", node(result, "surplus_node")[:value]
    assert_balanced(result)
  end

  test "empty graph and uncategorized identifiers are deterministic" do
    assert_empty graph[:nodes]
    assert_empty graph[:links]
    transaction(10, nil)
    assert_equal "10.0", node(graph, "expense_uncategorized")[:value]
    assert_equal graph, graph
  end

  private
    def transaction(amount, category)
      create_transaction(account: @account, amount: amount, category: category, date: @month)
    end

    def graph
      IncomeStatement::Sankey.new(IncomeStatement.new(@family), period: Period.custom(start_date: @month, end_date: @month.end_of_month)).as_json
    end

    def node(graph, id)
      graph[:nodes].find { |node| node[:id] == id }
    end

    def assert_balanced(graph)
      center = graph[:nodes].index { |node| node[:id] == "cash_flow_node" }
      incoming = graph[:links].select { |link| link[:target] == center }.sum { |link| link[:value].to_d }
      outgoing = graph[:links].select { |link| link[:source] == center }.sum { |link| link[:value].to_d }
      assert_equal incoming, outgoing
      graph[:nodes].each_with_index do |node, index|
        %i[source target].each do |end_point|
          allocated = graph[:links].select { |link| link[end_point] == index }.sum { |link| link[:value].to_d }
          assert_operator allocated, :<=, node[:value].to_d
        end
      end
    end
end
