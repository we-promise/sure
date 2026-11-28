require "test_helper"

class Balance::SearchTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @other_account = accounts(:credit_card)
    @scope = Balance.where(account_id: [ @account.id, @other_account.id ])
    @usd_jan = @account.balances.create!(date: Date.new(2024, 1, 15), balance: 100, currency: "USD")
    @eur_jan = @account.balances.create!(date: Date.new(2024, 1, 16), balance: 100, currency: "EUR")
    @usd_feb = @other_account.balances.create!(date: Date.new(2024, 2, 1), balance: 100, currency: "USD")
  end

  test "filters start off" do
    assert_equal @scope.to_a.sort_by(&:id), search.balances_scope.to_a.sort_by(&:id)
  end

  test "filters by account" do
    assert_equal [ @usd_feb ], search(account_id: @other_account.id).balances_scope.to_a
  end

  test "filters by currency in any case" do
    results = search(currency: "eur").balances_scope

    assert_includes results, @eur_jan
    assert_not_includes results, @usd_jan
  end

  test "filters by an inclusive date range, either end open" do
    assert_equal [ @usd_jan ], search(start_date: Date.new(2024, 1, 15), end_date: Date.new(2024, 1, 15)).balances_scope.to_a
    assert_equal [ @usd_feb ], search(start_date: Date.new(2024, 1, 17), end_date: Date.new(2024, 2, 1)).balances_scope.to_a
    assert_not_includes search(start_date: Date.new(2024, 1, 16)).balances_scope, @usd_jan
    assert_not_includes search(end_date: Date.new(2024, 1, 31)).balances_scope, @usd_feb
  end

  test "never widens the scope it is given" do
    narrowed = @scope.where(account_id: @account.id)

    assert_empty Balance::Search.new(narrowed, filters: { account_id: @other_account.id }).balances_scope
  end

  private

    def search(**filters)
      Balance::Search.new(@scope, filters:)
    end
end
