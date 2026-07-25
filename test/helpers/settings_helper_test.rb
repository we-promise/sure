# frozen_string_literal: true

require "test_helper"

class SettingsHelperTest < ActionView::TestCase
  test "provider_summary for snaptrade is off when family has no snaptrade items" do
    @snaptrade_items = []

    assert_equal({ status: :off }, provider_summary("snaptrade"))
  end

  test "provider_summary for snaptrade is off when no item has completed OAuth" do
    item = OpenStruct.new(oauth_configured?: false)
    @snaptrade_items = [ item ]

    assert_equal({ status: :off }, provider_summary("snaptrade"))
  end

  test "provider_summary for snaptrade reports sync-based status once an item is oauth configured" do
    item = OpenStruct.new(oauth_configured?: true)
    @snaptrade_items = [ item ]
    @provider_sync_health = {}

    assert_equal({ status: :ok, last_synced_at: nil }, provider_summary("snaptrade"))
  end
end
