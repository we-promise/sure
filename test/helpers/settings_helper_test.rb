# frozen_string_literal: true

require "test_helper"

class SettingsHelperTest < ActionView::TestCase
  # Views get every helper; the Trade Republic summary uses its expiry helper.
  include TradeRepublicHelper

  test "Enable Banking cooldown is a warning while unrelated failures remain errors" do
    waiting = EnableBankingItem.new(session_id: "session", session_expires_at: 30.days.from_now,
                                   next_sync_at: 6.hours.from_now, sync_retry_reason: "rate_limited")
    waiting.stubs(:sync_error).returns("throttled")
    @enable_banking_items = [ waiting ]
    @provider_sync_health = { "enable_banking" => { error: true } }
    assert_equal :warn, provider_summary("enable_banking")[:status]
    assert_includes provider_summary("enable_banking")[:meta], "Automatic retry"

    broken = EnableBankingItem.new
    broken.stubs(:sync_error).returns("bad credentials")
    @enable_banking_items << broken
    assert_equal :err, provider_summary("enable_banking")[:status]
  end

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

  test "provider_summary follows Directa authentication, first snapshot, health, error, and reconnect states" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    item = DirectaItem.new(status: :pending)
    @directa_items = []

    assert_equal :off, provider_summary("directa")[:status]

    @directa_item = item

    assert_equal :warn, provider_summary("directa")[:status]
    assert_equal I18n.t("settings.providers.directa_panel.sign_in_required"), provider_summary("directa")[:meta]

    item.assign_attributes(
      status: :connected,
      broker_account: "00123",
      account_identity: "00123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      last_sync_error_code: "awaiting_valuation"
    )
    awaiting_snapshot = provider_summary("directa")
    assert_equal :warn, awaiting_snapshot[:status]
    assert_equal I18n.t("settings.providers.directa_panel.waiting_for_snapshot"), awaiting_snapshot[:meta]

    item.last_sync_error_code = "partial_snapshot"
    assert_equal :err, provider_summary("directa")[:status]

    item.assign_attributes(portfolio_snapshot_at: Time.current, last_sync_error_code: nil)
    assert_equal :ok, provider_summary("directa")[:status]

    item.last_sync_error_code = "partial_snapshot"
    assert_equal :err, provider_summary("directa")[:status]

    item.status = :requires_update
    reconnect = provider_summary("directa")
    assert_equal :warn, reconnect[:status]
    assert_equal I18n.t("settings.providers.directa_panel.sign_in_required"), reconnect[:meta]
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
