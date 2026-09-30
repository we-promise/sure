require "test_helper"

class IncomeStatement::AccountSankeyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @current = accounts(:depository)
    @card = accounts(:credit_card)
    # A date no fixture uses, so the period holds only these transactions.
    @date = Date.new(2020, 1, 15)
    @period = Period.custom(start_date: @date.beginning_of_month, end_date: @date.end_of_month)

    @salary = @family.categories.create!(name: "Sankey Salary", color: "#10A861")
    @groceries = @family.categories.create!(name: "Sankey Groceries", color: "#FF5733")
    @shopping = @family.categories.create!(name: "Sankey Shopping", color: "#3357FF")

    create_transaction(account: @current, date: @date, amount: -1000, category: @salary, name: "Pay")
    create_transaction(account: @current, date: @date, amount: 200, category: @groceries, name: "Shop")
    create_transaction(account: @card, date: @date, amount: 300, category: @shopping, name: "Online")
  end

  test "routes income categories through each account to expense categories" do
    data = sankey

    assert_link data, "income_#{@salary.id}", "account_#{@current.id}", 1000
    assert_link data, "account_#{@current.id}", "expense_#{@groceries.id}", 200
    assert_link data, "account_#{@card.id}", "expense_#{@shopping.id}", 300
  end

  test "an account's leftover income flows to surplus and an overspent account is fed from deficit" do
    data = sankey

    assert_link data, "account_#{@current.id}", "surplus_node", 800
    assert_link data, "deficit_node", "account_#{@card.id}", 300
  end

  test "a category shared by several accounts is one node carrying the combined amount" do
    create_transaction(account: @card, date: @date, amount: 50, category: @groceries, name: "Card shop")

    data = sankey
    groceries = data[:nodes].select { |node| node[:id] == "expense_#{@groceries.id}" }

    assert_equal 1, groceries.size
    assert_equal 250.0, groceries.first[:value]
    assert_equal @groceries.filter_value, groceries.first[:filter_value]
  end

  test "accounts without flows in the period are left out" do
    ids = sankey[:nodes].map { |node| node[:id] }

    assert_not_includes ids, "account_#{accounts(:investment).id}"
  end

  private
    def sankey
      IncomeStatement::AccountSankey.new(@family, user: @user, period: @period,
        accounts: Account.where(id: [ @current.id, @card.id, accounts(:investment).id ])).as_json
    end

    def assert_link(data, source_id, target_id, value)
      index = ->(id) { data[:nodes].index { |node| node[:id] == id } }
      source, target = index.call(source_id), index.call(target_id)
      assert source, "missing node #{source_id}"
      assert target, "missing node #{target_id}"

      link = data[:links].find { |l| l[:source] == source && l[:target] == target }
      assert link, "missing link #{source_id} -> #{target_id}"
      assert_in_delta value, link[:value], 0.01
    end
end
