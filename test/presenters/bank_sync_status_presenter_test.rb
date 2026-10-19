# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "minitest/autorun"
require_relative "../../config/environment"

class BankSyncStatusPresenterTest < Minitest::Test
  def test_background_wait_does_not_disable_a_manual_enable_banking_refresh
    now = Time.current
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: now - 2.hours,
      sync_retry_reason: nil,
      sync_retry_pending?: false,
      sync_rate_limited?: false,
      sync_eligible_at: nil,
      sync_cooldown?: false,
      next_background_sync_at: now + 6.hours,
      sync_retry_at: nil
    )

    presentation = presenter(item, :enable_banking, background_sync_enabled: true)

    assert_equal :scheduled, presentation.state
    assert_equal false, presentation.manual_refresh_blocked?
    assert_includes presentation.timing_message, "Next background check"
    assert_includes presentation.timing_message, "A manual refresh is available now"
  end

  def test_hard_enable_banking_rate_limit_shows_effective_retry_and_retained_snapshot
    now = Time.current
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: now - 3.hours,
      sync_retry_reason: "rate_limited",
      sync_retry_pending?: true,
      sync_rate_limited?: true,
      sync_eligible_at: now + 6.hours,
      sync_cooldown?: true,
      next_background_sync_at: now + 6.hours,
      sync_retry_at: now + 6.hours
    )

    Time.use_zone("Europe/Rome") do
      presentation = presenter(item, :enable_banking, background_sync_enabled: true)

      assert_equal :rate_limited, presentation.state
      assert_equal :warning, presentation.variant
      assert presentation.manual_refresh_blocked?
      assert_includes presentation.timing_message, "Automatic retry is due after"
      assert_includes presentation.timing_message, "(Europe/Rome)"
      assert_includes presentation.stale_data_message, "Previously saved data remains available"
      assert_includes presentation.last_successful_message, "Last successful data snapshot"
    end
  end

  def test_expired_enable_banking_consent_does_not_promise_automatic_retry
    now = Time.current
    retry_at = now + 3.hours
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "expired-session",
      session_valid?: false,
      needs_authorization?: true,
      last_successful_sync_at: now - 1.day,
      sync_retry_reason: "rate_limited",
      sync_retry_pending?: true,
      sync_rate_limited?: true,
      sync_eligible_at: retry_at,
      sync_cooldown?: true,
      next_background_sync_at: now + 1.hour,
      sync_retry_at: retry_at
    )

    presentation = presenter(item, :enable_banking, background_sync_enabled: true)

    assert_equal :reconnect_required, presentation.state
    assert_includes presentation.timing_message, "Manual refresh is available after"
    refute_includes presentation.timing_message, "Automatic retry"
    refute_includes presentation.timing_message, "Next background check"
    refute_includes presentation.timing_message, "available now"
  end

  def test_expired_rate_limit_deadline_does_not_show_a_past_retry_time
    now = Time.current
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: now - 3.hours,
      sync_retry_reason: "rate_limited",
      sync_retry_pending?: true,
      sync_rate_limited?: false,
      sync_eligible_at: now - 1.minute,
      sync_cooldown?: false,
      next_background_sync_at: nil,
      sync_retry_at: now - 1.minute
    )

    presentation = presenter(item, :enable_banking, background_sync_enabled: false)

    assert_equal :rate_limited, presentation.state
    refute presentation.manual_refresh_blocked?
    assert_includes presentation.timing_message, "retry is due"
    assert_includes presentation.timing_message, "A manual refresh is available now"
    refute_includes presentation.timing_message, "ago"
  end

  def test_retryable_temporary_failure_is_warning_and_keeps_last_snapshot_visible
    now = Time.current
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: now - 4.hours,
      sync_retry_reason: "temporary_error",
      sync_retry_pending?: true,
      sync_rate_limited?: false,
      sync_eligible_at: now + 15.minutes,
      sync_cooldown?: true,
      next_background_sync_at: now + 2.hours,
      sync_retry_at: now + 2.hours
    )

    presentation = presenter(item, :enable_banking, background_sync_enabled: true)

    assert_equal :temporary_error, presentation.state
    assert_equal :warning, presentation.variant
    assert_equal :warn, presentation.summary_status
    assert_includes presentation.stale_data_message, "Previously saved data remains available"
    assert_includes presentation.last_successful_message, "Last successful data snapshot"
  end

  def test_legacy_deferred_summary_error_is_removed_without_hiding_account_errors
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: 4.hours.ago,
      sync_retry_reason: "rate_limited",
      sync_retry_pending?: true,
      sync_rate_limited?: true,
      sync_eligible_at: 1.hour.from_now,
      sync_cooldown?: true
    )
    presentation = presenter(item, :enable_banking, background_sync_enabled: false)
    stats = {
      "total_errors" => 2,
      "errors" => [
        { "message" => "retry deferred", "category" => "sync_deferred" },
        { "message" => "one account failed", "category" => "account_error" }
      ]
    }

    cleaned = presentation.sync_summary_stats(stats)

    assert_equal 1, cleaned["total_errors"]
    assert_equal [ "account_error" ], cleaned["errors"].map { |error| error["category"] }
  end

  def test_legacy_rate_limit_flag_without_error_details_does_not_count_as_an_error
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: 4.hours.ago,
      sync_retry_reason: "rate_limited",
      sync_retry_pending?: true,
      sync_rate_limited?: true,
      sync_eligible_at: 1.hour.from_now,
      sync_cooldown?: true
    )
    presentation = presenter(item, :enable_banking, background_sync_enabled: false)

    cleaned = presentation.sync_summary_stats("total_errors" => 1, "rate_limited" => true, "errors" => [])

    assert_equal 0, cleaned["total_errors"]
    assert_equal true, cleaned["rate_limited"]
  end

  def test_directa_history_rate_limit_is_not_a_terminal_error_or_automatic_retry_claim
    now = Time.current
    item = item_with(
      syncing?: false,
      requires_update?: false,
      session_configured?: true,
      history_sync_error_code: "history_rate_limited",
      sync_rate_limited?: true,
      sync_cooldown?: true,
      sync_eligible_at: now + 5.minutes,
      portfolio_snapshot_at: now - 1.day
    )

    presentation = presenter(item, :directa)

    assert_equal :rate_limited, presentation.state
    assert_equal :warn, presentation.summary_status
    assert_includes presentation.timing_message, "Manual refresh is available after"
    refute_includes presentation.timing_message, "Automatic retry"
    assert_includes presentation.last_successful_message, "Last successful data snapshot"
  end

  def test_scalable_cooldown_is_manual_eligibility_not_an_automatic_retry
    now = Time.current
    item = item_with(
      syncing?: false,
      requires_update?: false,
      session_configured?: true,
      next_sync_at: now + 15.minutes,
      sync_due?: false,
      snapshot_at: now - 2.days,
      error_message: nil
    )

    presentation = presenter(item, :scalable)

    assert_equal :scheduled, presentation.state
    assert presentation.manual_refresh_blocked?
    assert_includes presentation.timing_message, "Manual refresh is available after"
    refute_includes presentation.timing_message, "Automatic retry"
  end

  def test_reconnect_status_keeps_the_last_successful_fineco_snapshot
    now = Time.current
    item = item_with(
      syncing?: false,
      requires_update?: true,
      session_configured?: false,
      portfolio_snapshot_at: now - 1.week,
      last_synced_at: now
    )

    presentation = presenter(item, :fineco)

    assert_equal :reconnect_required, presentation.state
    assert_equal now - 1.week, presentation.last_successful_at
    assert_includes presentation.last_successful_message, "Last successful data snapshot"
    assert_includes presentation.stale_data_message, "Previously saved data remains available"
  end

  def test_paused_verified_fineco_connection_requires_reconnect_without_a_snapshot
    item = item_with(
      syncing?: false,
      requires_update?: true,
      session_configured?: false,
      bank_account_number: "123456",
      dossier_identity: "a" * 64,
      portfolio_snapshot_at: nil
    )

    presentation = presenter(item, :fineco)

    assert_equal :reconnect_required, presentation.state
    assert_equal :warn, presentation.summary_status
  end

  def test_fineco_without_a_verified_connection_still_requires_initial_connection
    item = item_with(
      syncing?: false,
      requires_update?: false,
      session_configured?: false,
      portfolio_snapshot_at: nil
    )

    presentation = presenter(item, :fineco)

    assert_equal :connection_required, presentation.state
  end

  def test_enable_banking_partial_import_keeps_last_fully_successful_timestamp_visible
    now = Time.current
    latest_sync = Struct.new(:sync_stats).new({ "partial_import" => true, "total_errors" => 2 })
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: now - 5.hours,
      latest_sync_record: latest_sync,
      sync_retry_reason: nil
    )

    presentation = presenter(item, :enable_banking, background_sync_enabled: false)

    assert_equal :partial_import, presentation.state
    assert_equal :warning, presentation.variant
    assert_equal :warn, presentation.summary_status
    assert_includes presentation.message, "Some data could not be refreshed"
    assert_includes presentation.stale_data_message, "Previously saved data remains available"
    assert_equal now - 5.hours, presentation.last_successful_at
    assert_includes presentation.last_successful_message, "Last successful data snapshot"
  end

  def test_background_wait_uses_later_shared_rate_limit_deadline
    now = Time.current
    background_at = now + 1.hour
    shared_limit_until = now + 3.hours
    item = item_with(
      syncing?: false,
      requires_update?: false,
      credentials_configured?: true,
      session_id: "active-session",
      session_valid?: true,
      last_successful_sync_at: now - 2.hours,
      sync_retry_reason: nil,
      sync_rate_limited?: true,
      sync_rate_limited_until: shared_limit_until,
      sync_eligible_at: shared_limit_until,
      sync_cooldown?: true,
      next_background_sync_at: background_at,
      sync_retry_at: nil
    )

    presentation = presenter(item, :enable_banking, background_sync_enabled: true)

    assert_equal :rate_limited, presentation.state
    assert_includes presentation.timing_message, I18n.l(shared_limit_until, format: :long)
    refute_includes presentation.timing_message, I18n.l(background_at, format: :long)
  end

  private

    def item_with(attributes)
      Object.new.tap do |item|
        attributes.each do |method_name, value|
          item.define_singleton_method(method_name) { value }
        end
      end
    end

    def presenter(item, provider_key, background_sync_enabled: false)
      BankSyncStatusPresenter.new(
        item: item,
        provider_key: provider_key,
        background_sync_enabled: background_sync_enabled
      )
    end
end
