# frozen_string_literal: true

require "test_helper"

class SettingsHelperTest < ActionView::TestCase
  test "provider_summary for snaptrade is off when family has no snaptrade items" do
    @snaptrade_items = []

    assert_equal({ status: :off }, provider_summary("snaptrade"))
  end

  test "provider_summary for snaptrade is off when no item holds credentials" do
    item = OpenStruct.new(credentials_configured?: false, fully_configured?: false)
    @snaptrade_items = [ item ]

    assert_equal({ status: :off }, provider_summary("snaptrade"))
  end

  test "provider_summary for snaptrade warns while a device-flow item awaits registration" do
    item = OpenStruct.new(credentials_configured?: true, fully_configured?: false)
    @snaptrade_items = [ item ]

    assert_equal(
      { status: :warn, meta: I18n.t("settings.providers.meta.registration_needed") },
      provider_summary("snaptrade")
    )
  end

  test "provider_summary for snaptrade reports sync-based status once an item is connected" do
    item = OpenStruct.new(credentials_configured?: true, fully_configured?: true)
    @snaptrade_items = [ item ]
    @provider_sync_health = {}

    assert_equal({ status: :ok, last_synced_at: nil }, provider_summary("snaptrade"))
  end
end
