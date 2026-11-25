require "test_helper"

class Holding::SearchTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @other_account = accounts(:crypto)
    @scope = Holding.where(account_id: [ @account.id, @other_account.id ])

    @old = @account.holdings.create!(security: securities(:msft), date: Date.new(2024, 1, 10), qty: 1, price: 10, amount: 10, currency: "USD")
    @mid = @account.holdings.create!(security: securities(:aapl), date: Date.new(2024, 1, 20), qty: 1, price: 10, amount: 10, currency: "USD")
    @elsewhere = @other_account.holdings.create!(security: securities(:aapl), date: Date.new(2024, 1, 20), qty: 1, price: 10, amount: 10, currency: "USD")
  end

  test "with no filters returns the scope it is given" do
    assert_equal @scope.to_a.sort_by(&:id), search.holdings_scope.to_a.sort_by(&:id)
  end

  test "filters by account_id and by account_ids, intersecting both" do
    assert_equal [ @elsewhere ], search(account_id: @other_account.id).holdings_scope.where(date: Date.new(2024, 1, 20)).to_a
    assert_equal [ @mid ], search(account_ids: [ @account.id ]).holdings_scope.where(date: Date.new(2024, 1, 20)).to_a
    assert_empty search(account_id: @other_account.id, account_ids: [ @account.id ]).holdings_scope
  end

  test "filters by security" do
    assert_equal [ @old ], search(security_id: securities(:msft).id).holdings_scope.to_a
  end

  test "filters by exact date and by an inclusive date range" do
    january = search(start_date: Date.new(2024, 1, 10), end_date: Date.new(2024, 1, 20)).holdings_scope

    assert_equal [ @mid, @elsewhere ].sort_by(&:id), search(date: Date.new(2024, 1, 20)).holdings_scope.to_a.sort_by(&:id)
    assert_equal [ @old, @mid, @elsewhere ].sort_by(&:id), january.to_a.sort_by(&:id)
    assert_equal [ @old ], search(end_date: Date.new(2024, 1, 19)).holdings_scope.where(account_id: @account.id).to_a
  end

  test "never reaches holdings outside the scope it is given" do
    outside = Holding.where.not(account_id: [ @account.id, @other_account.id ]).first ||
      accounts(:depository).holdings.create!(security: securities(:aapl), date: Date.new(2024, 1, 20), qty: 1, price: 1, amount: 1, currency: "USD")

    assert_not_includes search(account_id: outside.account_id).holdings_scope, outside
  end

  private
    def search(**filters)
      Holding::Search.new(@scope, filters:)
    end
end
