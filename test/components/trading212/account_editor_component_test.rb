require "test_helper"

class Trading212::AccountEditorComponentTest < ViewComponent::TestCase
  test "precomputes sync status summaries for all items" do
    item = trading212_items(:configured_item)
    trading212_accounts(:main_account).ensure_account_provider!(accounts(:investment))
    item.trading212_accounts.create!(
      name: "Trading 212 unlinked account",
      trading212_account_id: "t212_unlinked_component_test",
      currency: "USD",
      current_balance: 1000,
      cash_balance: 100,
      raw_positions_payload: [],
      raw_orders_payload: [],
      raw_dividends_payload: [],
      raw_transactions_payload: []
    )

    component = Trading212::AccountEditorComponent.new(items: [ item ], family: item.family)

    queries = capture_sql_queries do
      assert_equal I18n.t("trading212_items.sync_status.partial", linked: 1, unlinked: 1),
                   component.sync_status_summary_for(item)
    end

    assert_empty queries
  end
end
