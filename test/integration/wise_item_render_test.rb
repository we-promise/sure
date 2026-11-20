require "test_helper"

class WiseItemRenderTest < ActiveSupport::TestCase
  # A failed Wise fetch leaves the sync completed, so the card's only signal
  # is the sync summary built from the latest sync's stats.
  test "the connection card shows the latest sync's errors" do
    Current.reset
    wise_item = wise_items(:one)
    message = I18n.t("wise_items.syncer.fetch_failed", count: 1)
    wise_item.syncs.create!(status: :completed, completed_at: Time.current, sync_stats: {
      "import_started" => true, "total_errors" => 1, "errors" => [ { "message" => message, "category" => "fetch_error" } ]
    })

    html = ApplicationController.render(
      partial: "wise_items/wise_item",
      locals: { wise_item: wise_item, visible_accounts: wise_item.accounts }
    )

    assert_includes html, I18n.t("provider_sync_summary.title")
    assert_includes html, message
  end
end
