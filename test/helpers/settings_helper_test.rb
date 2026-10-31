# frozen_string_literal: true

require "test_helper"

class SettingsHelperTest < ActionView::TestCase
  # Views get every helper; the Trade Republic summary uses its expiry helper.
  include TradeRepublicHelper

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

  test "provider_summary for trading212 reports sync-based status when connected" do
    @trading212_items = [ OpenStruct.new ]
    @provider_sync_health = {}

    assert_equal({ status: :ok, last_synced_at: nil }, provider_summary("trading212"))
  end

  test "provider_summary for trading212 is off without connections" do
    @trading212_items = []

    assert_equal({ status: :off }, provider_summary("trading212"))
  end

  test "provider_summary for enable_banking asks for re-consent when the bank rejected an unexpired session" do
    @enable_banking_items = [ EnableBankingItem.new(session_id: "session", session_expires_at: 30.days.from_now, status: :requires_update) ]

    summary = provider_summary("enable_banking")

    assert_equal :warn, summary[:status]
    assert_equal I18n.t("settings.providers.meta.reconsent_required"), summary[:meta]
  end

  # A key provider_summary doesn't handle falls through to { status: :off },
  # which lists a connected provider under Available. Wise and CoinSpot
  # shipped that way. One key at a time, so a branch that reads another
  # provider's items fails too.
  test "provider_summary is not off for any connected family panel provider" do
    item = OpenStruct.new(oauth_configured?: true)

    off = Settings::ProvidersController::FAMILY_PANEL_KEYS.select do |key|
      instance_variable_set(:"@#{key}_items", [ item ])
      status = provider_summary(key)[:status]
      instance_variable_set(:"@#{key}_items", nil)
      status == :off
    end

    assert_empty off
  end

  test "provider_summary for trade_republic asks for a new login once a session has expired" do
    @trade_republic_items = [ TradeRepublicItem.new(session_blob: "session", session_expires_at: 1.minute.ago) ]
    @provider_sync_health = {}

    summary = provider_summary("trade_republic")

    assert_equal :warn, summary[:status]
    assert_equal I18n.t("settings.providers.meta.login_required"), summary[:meta]
  end

  test "provider_summary for trade_republic asks for a new login after a failed last sync" do
    @trade_republic_items = [ TradeRepublicItem.new(session_blob: "session", session_expires_at: 1.minute.ago) ]
    @provider_sync_health = { "trade_republic" => { error: true } }

    summary = provider_summary("trade_republic")

    assert_equal :warn, summary[:status]
    assert_equal I18n.t("settings.providers.meta.login_required"), summary[:meta]
  end

  test "provider_summary for trade_republic reports a failed sync while the login is valid" do
    @trade_republic_items = [ TradeRepublicItem.new(session_blob: "session", session_expires_at: 5.hours.from_now) ]
    @provider_sync_health = { "trade_republic" => { error: true } }

    summary = provider_summary("trade_republic")

    assert_equal :err, summary[:status]
    assert_equal I18n.t("settings.providers.meta.sync_error"), summary[:meta]
  end

  test "provider_summary for trade_republic warns shortly before a login expires" do
    expires_at = 90.minutes.from_now
    @trade_republic_items = [ TradeRepublicItem.new(session_blob: "session", session_expires_at: expires_at) ]
    @provider_sync_health = {}

    summary = provider_summary("trade_republic")

    assert_equal :warn, summary[:status]
    assert_equal I18n.t("settings.providers.meta.login_expires_soon", time: "about 2 hours", at: I18n.l(expires_at, format: :short)), summary[:meta]
  end

  test "provider_summary for trade_republic reports sync-based status while the login is valid" do
    @trade_republic_items = [ TradeRepublicItem.new(session_blob: "session", session_expires_at: 5.hours.from_now) ]
    @provider_sync_health = {}

    assert_equal({ status: :ok, last_synced_at: nil }, provider_summary("trade_republic"))
  end
end
