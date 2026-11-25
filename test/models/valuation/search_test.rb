require "test_helper"

class Valuation::SearchTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @other_account = accounts(:investment)
    @scope = families(:dylan_family).entries.valuations.where(account_id: [ @account.id, @other_account.id ])
    @jan = create_valuation(@account, Date.new(2024, 1, 15))
    @feb = create_valuation(@other_account, Date.new(2024, 2, 1))
  end

  test "filters start off" do
    assert_equal @scope.to_a.sort_by(&:id), search.valuations_scope.to_a.sort_by(&:id)
  end

  test "filters by account" do
    results = search(account_id: @other_account.id).valuations_scope

    assert_includes results, @feb
    assert results.all? { |entry| entry.account_id == @other_account.id }
  end

  test "filters by an inclusive date range, either end open" do
    assert_equal [ @jan ], search(start_date: @jan.date, end_date: @jan.date).valuations_scope.to_a
    assert_equal [ @feb ], search(start_date: Date.new(2024, 1, 16), end_date: Date.new(2024, 2, 1)).valuations_scope.to_a
    assert_not_includes search(end_date: Date.new(2024, 1, 31)).valuations_scope, @feb
    assert_not_includes search(start_date: Date.new(2024, 1, 16)).valuations_scope, @jan
  end

  test "never widens the scope it is given" do
    narrowed = @scope.where(account_id: @account.id)

    assert_empty Valuation::Search.new(narrowed, filters: { account_id: @other_account.id }).valuations_scope
  end

  private

    def search(**filters)
      Valuation::Search.new(@scope, filters:)
    end

    def create_valuation(account, date)
      account.entries.create!(name: "Balance", date:, amount: 100, currency: "USD",
                              entryable: Valuation.new(kind: "reconciliation"))
    end
end
