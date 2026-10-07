require "test_helper"
require "turbo/broadcastable/test_helper"

class EnableBankingItem::SyncCompleteEventTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  CERTIFICATE_MARKER = "SYNCEVENTCERTMARKER"

  setup do
    @family = families(:dylan_family)
    @item = @family.enable_banking_items.create!(
      name: "Test Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: "-----BEGIN PRIVATE KEY-----\n#{CERTIFICATE_MARKER}\n-----END PRIVATE KEY-----"
    )
    Current.reset
  end

  # Every member of the family subscribes to the family stream, but the
  # Settings > Providers panel is admin-only and its form holds the stored
  # client certificate.
  test "a finished sync does not stream the settings panel to the family" do
    streams = capture_turbo_stream_broadcasts(@family) do
      EnableBankingItem::SyncCompleteEvent.new(@item).broadcast
    end

    assert_empty streams.select { |stream| stream["target"] == "enable_banking-providers-panel" }
    streams.each { |stream| assert_not_includes stream.to_html, CERTIFICATE_MARKER }
  end

  test "a finished sync still refreshes the connection card and the sync toast" do
    targets = capture_turbo_stream_broadcasts(@family) do
      EnableBankingItem::SyncCompleteEvent.new(@item).broadcast
    end.map { |stream| stream["target"] }

    assert_includes targets, "enable_banking_item_#{@item.id}"
    assert_includes targets, "sync-toast"
  end
end
