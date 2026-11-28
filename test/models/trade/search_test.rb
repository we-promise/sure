require "test_helper"

class Trade::SearchTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:investment)
    @other_account = accounts(:crypto)
    @scope = Trade.with_entry.where(entries: { account_id: [ @account.id, @other_account.id ] })

    @early = create_trade(@account, Date.new(2024, 1, 10))
    @late = create_trade(@account, Date.new(2024, 1, 20))
    @elsewhere = create_trade(@other_account, Date.new(2024, 1, 20))
  end

  test "with no filters returns the scope it is given" do
    assert_equal @scope.to_a.sort_by(&:id), search.trades_scope.to_a.sort_by(&:id)
  end

  test "filters by account_id and by account_ids, intersecting both" do
    assert_equal [ @elsewhere ], search(account_id: @other_account.id).trades_scope.to_a
    assert_includes search(account_ids: [ @account.id ]).trades_scope, @late
    assert_not_includes search(account_ids: [ @account.id ]).trades_scope, @elsewhere
    assert_empty search(account_id: @other_account.id, account_ids: [ @account.id ]).trades_scope
  end

  test "filters by an inclusive date range on the entry date" do
    range = search(start_date: Date.new(2024, 1, 10), end_date: Date.new(2024, 1, 19)).trades_scope

    assert_equal [ @early ], range.to_a
    from_late = search(start_date: Date.new(2024, 1, 20)).trades_scope
    assert_includes from_late, @late
    assert_includes from_late, @elsewhere
    assert_not_includes from_late, @early
  end

  test "works on a scope that has not joined entries yet" do
    assert_equal [ @early ], Trade::Search.new(Trade.all, filters: { end_date: Date.new(2024, 1, 10) }).trades_scope.where(id: [ @early.id, @late.id ]).to_a
  end

  private
    def search(**filters)
      Trade::Search.new(@scope, filters:)
    end

    def create_trade(account, date)
      account.entries.create!(
        name: "Buy", date:, amount: 100, currency: "USD",
        entryable: Trade.new(security: securities(:aapl), qty: 1, price: 100, currency: "USD")
      ).entryable
    end
end
