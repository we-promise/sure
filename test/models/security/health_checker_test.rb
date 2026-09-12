require "test_helper"

class Security::HealthCheckerTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    # Clean slate
    Holding.destroy_all
    Trade.destroy_all
    Security::Price.delete_all
    Security.delete_all

    @provider = mock
    Security.any_instance.stubs(:price_data_provider).returns(@provider)

    # Brand new, no health check has been run yet
    @new_security = Security.create!(
      ticker: "NEW",
      offline: false,
      last_health_check_at: nil
    )

    # New security, offline
    # This will be checked, but unless it gets a price, we keep it offline
    @new_offline_security = Security.create!(
      ticker: "NEW_OFFLINE",
      offline: true,
      last_health_check_at: nil
    )

    # Online, recently checked, healthy
    @healthy_security = Security.create!(
      ticker: "HEALTHY",
      offline: false,
      last_health_check_at: 2.hours.ago
    )

    # Online, due for a health check
    @due_for_check_security = Security.create!(
      ticker: "DUE",
      offline: false,
      last_health_check_at: Security::HealthChecker::HEALTH_CHECK_INTERVAL.ago - 1.day
    )

    # Offline, recently checked (keep offline, don't check)
    @offline_security = Security.create!(
      ticker: "OFFLINE",
      offline: true,
      last_health_check_at: 20.days.ago
    )

    # Currently offline, but has had no health check and actually has prices (needs to convert to "online")
    @offline_never_checked_with_prices = Security.create!(
      ticker: "OFFLINE_NEVER_CHECKED",
      offline: true,
      last_health_check_at: nil
    )
  end

  test "any security without a health check runs" do
    to_check = Security.where(last_health_check_at: nil).or(Security.where(last_health_check_at: ..Security::HealthChecker::HEALTH_CHECK_INTERVAL.ago))
    Security::HealthChecker.any_instance.expects(:run_check).times(to_check.count)
    Security::HealthChecker.check_all
  end

  test "offline security with no health check that fails stays offline" do
    hc = Security::HealthChecker.new(@new_offline_security)

    @provider.expects(:fetch_security_price)
      .with(
        symbol: @new_offline_security.ticker,
        exchange_operating_mic: @new_offline_security.exchange_operating_mic,
        date: Date.current
      )
      .returns(
        provider_error_response(StandardError.new("No prices found"))
      )
      .once

    hc.run_check

    assert_equal 1, @new_offline_security.failed_fetch_count
    assert @new_offline_security.offline?
  end

  test "after enough consecutive health check failures, security with existing price history goes offline but keeps its prices" do
    # Create one test price
    Security::Price.create!(
      security: @due_for_check_security,
      date: Date.current,
      price: 100,
      currency: "USD"
    )

    hc = Security::HealthChecker.new(@due_for_check_security)

    @provider.expects(:fetch_security_price)
      .with(
        symbol: @due_for_check_security.ticker,
        exchange_operating_mic: @due_for_check_security.exchange_operating_mic,
        date: Date.current
      )
      .returns(provider_error_response(StandardError.new("No prices found")))
      .times(Security::HealthChecker::MAX_CONSECUTIVE_FAILURES + 1)

    Security::HealthChecker::MAX_CONSECUTIVE_FAILURES.times do
      hc.run_check
    end

    refute @due_for_check_security.offline?
    assert_equal 1, @due_for_check_security.prices.count

    # We've now exceeded the max consecutive failures, so the security should be marked offline —
    # but since it had a real, previously-fetched price, five failed *new* fetches don't make that
    # existing history untrustworthy, so it must be preserved.
    assert_difference "DebugLogEntry.count", 1 do
      hc.run_check
    end
    assert @due_for_check_security.offline?
    assert_equal "health_check_failed", @due_for_check_security.offline_reason
    assert_equal 1, @due_for_check_security.prices.count, "Existing price history must be preserved"

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "security_health_check", entry.category
    assert_equal "error", entry.level
    assert_equal true, entry.metadata["had_price_history"]
  end

  test "after enough consecutive health check failures, security with no prior price history goes offline with no prices to preserve" do
    hc = Security::HealthChecker.new(@due_for_check_security)

    @provider.expects(:fetch_security_price)
      .with(
        symbol: @due_for_check_security.ticker,
        exchange_operating_mic: @due_for_check_security.exchange_operating_mic,
        date: Date.current
      )
      .returns(provider_error_response(StandardError.new("No prices found")))
      .times(Security::HealthChecker::MAX_CONSECUTIVE_FAILURES + 1)

    Security::HealthChecker::MAX_CONSECUTIVE_FAILURES.times { hc.run_check }

    assert_difference "DebugLogEntry.count", 1 do
      hc.run_check
    end
    assert @due_for_check_security.offline?
    assert_equal 0, @due_for_check_security.prices.count

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "security_health_check", entry.category
    assert_equal "error", entry.level
    assert_equal false, entry.metadata["had_price_history"]
  end

  test "an intermediate (non-terminal) health check failure logs a warn-level debug entry" do
    hc = Security::HealthChecker.new(@due_for_check_security)

    @provider.expects(:fetch_security_price)
      .with(
        symbol: @due_for_check_security.ticker,
        exchange_operating_mic: @due_for_check_security.exchange_operating_mic,
        date: Date.current
      )
      .returns(provider_error_response(StandardError.new("No prices found")))
      .once

    assert_difference "DebugLogEntry.count", 1 do
      hc.run_check
    end

    refute @due_for_check_security.offline?
    entry = DebugLogEntry.order(:created_at).last
    assert_equal "security_health_check", entry.category
    assert_equal "warn", entry.level
    assert_equal 1, entry.metadata["failed_fetch_count"]
  end

  test "run_check does not count a missing/unavailable provider as a fetch failure" do
    # e.g. the security's assigned provider was disabled in settings —
    # offline_reason: "provider_disabled" is more specific than the generic
    # health-check failure path and must not be overwritten by it.
    @due_for_check_security.update!(offline: true, offline_reason: "provider_disabled", price_provider: "twelve_data")
    @due_for_check_security.stubs(:price_data_provider).returns(nil)

    hc = Security::HealthChecker.new(@due_for_check_security)

    @provider.expects(:fetch_security_price).never

    assert_no_difference "DebugLogEntry.count" do
      hc.run_check
    end

    assert @due_for_check_security.offline?
    assert_equal "provider_disabled", @due_for_check_security.offline_reason
    assert_equal 0, @due_for_check_security.failed_fetch_count
    assert_not_nil @due_for_check_security.reload.last_health_check_at, "Skipped checks still update last_health_check_at so they aren't re-queued daily"
  end

  test "failure incrementor increases for each health check failure" do
    hc = Security::HealthChecker.new(@due_for_check_security)

    @provider.expects(:fetch_security_price)
      .with(
        symbol: @due_for_check_security.ticker,
        exchange_operating_mic: @due_for_check_security.exchange_operating_mic,
        date: Date.current
      )
      .returns(provider_error_response(StandardError.new("No prices found")))
      .twice

    hc.run_check
    assert_equal 1, @due_for_check_security.failed_fetch_count

    hc.run_check
    assert_equal 2, @due_for_check_security.failed_fetch_count
  end

  test "failure incrementor resets to 0 when health check succeeds" do
    hc = Security::HealthChecker.new(@offline_never_checked_with_prices)

    @provider.expects(:fetch_security_price)
      .with(
        symbol: @offline_never_checked_with_prices.ticker,
        exchange_operating_mic: @offline_never_checked_with_prices.exchange_operating_mic,
        date: Date.current
      )
      .returns(provider_success_response(OpenStruct.new(price: 100, date: Date.current, currency: "USD")))
      .once

    assert @offline_never_checked_with_prices.offline?

    hc.run_check

    refute @offline_never_checked_with_prices.offline?
    assert_equal 0, @offline_never_checked_with_prices.failed_fetch_count
    assert_nil @offline_never_checked_with_prices.failed_fetch_at
  end
end
