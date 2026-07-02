require "test_helper"

class ProviderSyncSummaryTest < ViewComponent::TestCase
  test "shows inline error details for non-debug-log errors" do
    provider_item = plaid_items(:one)
    provider_item.define_singleton_method(:last_synced_at) { Time.current }

    render_inline(ProviderSyncSummary.new(
      stats: {
        "total_errors" => 1,
        "errors" => [
          { "name" => "Checking", "message" => "Partial import failed" }
        ]
      },
      provider_item: provider_item
    ))

    assert_text "View error details"
    assert_text "Checking: Partial import failed"
    assert_no_text "Details in debug log"
  end

  test "shows debug-log hint for provider sync placeholder errors" do
    provider_item = plaid_items(:one)
    provider_item.define_singleton_method(:last_synced_at) { Time.current }

    render_inline(ProviderSyncSummary.new(
      stats: {
        "total_errors" => 1,
        "errors" => [
          { "message" => "provider_sync_error" }
        ]
      },
      provider_item: provider_item
    ))

    assert_text "Details in debug log"
    assert_no_text "View error details"
    assert_no_text "provider_sync_error"
  end
end
