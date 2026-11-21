require "test_helper"

class IncomeStatement::DashboardSankeyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @month = Date.new(2024, 2, 1)
  end

  test "rounding to cents adds no surplus or deficit the period does not have" do
    transaction(-"0.015".to_d, category("Salary"))
    transaction(-"0.005".to_d, category("Interest"))
    %w[Food Fuel Fees Gifts].each { |name| transaction("0.005".to_d, category(name)) }

    result = graph
    assert_nil node(result, "surplus_node")
    assert_nil node(result, "deficit_node")
    assert_balanced result
  end

  test "surplus is the period's net rounded once, not the sum of rounded categories" do
    %w[Salary Interest Gifts].each { |name| transaction(-"0.005".to_d, category(name)) }

    result = graph
    assert_equal 0.02, node(result, "surplus_node")[:value]
    assert_balanced result
  end

  test "a parent's branches add up to the parent once both are in cents" do
    parent = category("Housing")
    child = @family.categories.create!(name: "HOA", parent: parent)
    transaction("1000.005".to_d, parent)
    transaction("200.005".to_d, child)

    result = graph
    assert_equal 1200.01, node(result, "expense_#{parent.id}")[:value]
    assert_balanced result
  end

  test "to_cents keeps the rounded total and each amount within a cent" do
    amounts = [ "0.015", "0.005", "-0.005", "-0.005", "-0.005", "-0.005" ].map(&:to_d)
    cents = IncomeStatement::DashboardSankey.to_cents(amounts, amounts.sum)

    assert_equal 0, cents.sum
    amounts.zip(cents).each { |amount, cent| assert_operator (amount - cent).abs, :<, "0.01".to_d }
    assert_equal [ "1.01", "2.00" ].map(&:to_d), IncomeStatement::DashboardSankey.to_cents([ "1.006", "1.999" ].map(&:to_d), "3.005".to_d)
  end

  private
    def category(name)
      @family.categories.create!(name: name, color: "#123456")
    end

    def transaction(amount, category)
      create_transaction(account: @account, amount: amount, category: category, date: @month)
    end

    def graph
      IncomeStatement::DashboardSankey.new(IncomeStatement.new(@family), period: Period.custom(start_date: @month, end_date: @month.end_of_month)).as_json
    end

    def node(graph, id)
      graph[:nodes].find { |node| node[:id] == id }
    end

    def assert_balanced(graph)
      graph[:nodes].each_with_index do |node, index|
        incoming, outgoing = %i[target source].map do |end_point|
          graph[:links].select { |link| link[end_point] == index }.sum { |link| link[:value].to_d }
        end
        assert_operator node[:value], :>, 0
        assert_equal incoming, outgoing, "#{node[:id]} must pass on what flows into it" if incoming.positive? && outgoing.positive?
        assert_equal node[:value].to_d, [ incoming, outgoing ].max, "#{node[:id]} must match its links"
      end
    end
end
