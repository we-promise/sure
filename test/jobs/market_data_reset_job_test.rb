require "test_helper"

class MarketDataResetJobTest < ActiveJob::TestCase
  Window = Security::Price::ImportWindows::Window

  setup do
    @security = securities(:aapl)
    @price_in_window = @security.prices.create!(date: 20.days.ago.to_date, price: 200, currency: "USD")
    @price_before_window = @security.prices.create!(date: 2.years.ago.to_date, price: 150, currency: "USD")
    @rate_in_window = exchange_rates(:one)
    @rate_before_window = ExchangeRate.create!(from_currency: "EUR", to_currency: "GBP", date: 2.years.ago.to_date, rate: 0.9)

    @securities_provider = stub(max_history_days: nil)
    @exchange_rate_provider = stub(max_history_days: nil)
    Security.stubs(:providers).returns([ @securities_provider ])
    ExchangeRate.stubs(:provider).returns(@exchange_rate_provider)

    MarketDataImporter.any_instance.stubs(:required_security_price_windows)
      .returns(@security.id => Window.new(start_date: 1.year.ago.to_date, end_date: Date.current))
    MarketDataImporter.any_instance.stubs(:required_exchange_rate_pairs)
      .returns([ { source: "EUR", target: "GBP", start_date: 1.year.ago.to_date } ])
  end

  test "deletes the data the import requests, re-imports it, then syncs every account" do
    sequence = sequence("reset")
    MarketDataImporter.any_instance.expects(:import_security_prices).in_sequence(sequence).with do
      assert_not Security::Price.exists?(@price_in_window.id), "prices must be gone before the re-import"
      true
    end
    MarketDataImporter.any_instance.expects(:import_exchange_rates).in_sequence(sequence).with do
      assert_not ExchangeRate.exists?(@rate_in_window.id), "rates must be gone before the re-import"
      assert_no_enqueued_jobs only: SyncJob
      true
    end

    MarketDataResetJob.perform_now

    assert Security::Price.exists?(@price_before_window.id), "prices outside the import window stay"
    assert ExchangeRate.exists?(@rate_before_window.id), "rates outside the import window stay"
    assert_enqueued_jobs Account.count, only: SyncJob
  end

  test "imports with the cache cleared so stored coverage does not shorten the request" do
    importer = MarketDataImporter.new(mode: :full, clear_cache: true)
    MarketDataImporter.expects(:new).with(mode: :full, clear_cache: true).returns(importer)
    stub_imports

    MarketDataResetJob.perform_now
  end

  test "keeps prices and rates older than the provider's history" do
    stub_imports
    @securities_provider.stubs(:max_history_days).returns(10)
    @exchange_rate_provider.stubs(:max_history_days).returns(0)

    MarketDataResetJob.perform_now

    assert Security::Price.exists?(@price_in_window.id), "20 days back is beyond a 10-day history"
    assert ExchangeRate.exists?(@rate_before_window.id)
    assert_not ExchangeRate.exists?(@rate_in_window.id), "today's rate is within a latest-only history"
  end

  test "keeps data that no configured provider can fetch again" do
    stub_imports
    ExchangeRate.stubs(:provider).returns(nil)
    Security.stubs(:providers).returns([])

    MarketDataResetJob.perform_now

    assert ExchangeRate.exists?(@rate_in_window.id)
    assert Security::Price.exists?(@price_in_window.id)
  end

  test "keeps offline securities, balances and holdings" do
    stub_imports
    offline = Security.create!(ticker: "OFFL", name: "Offline Co", offline: true)
    offline_price = offline.prices.create!(date: 20.days.ago.to_date, price: 10, currency: "USD")
    MarketDataImporter.any_instance.stubs(:required_security_price_windows)
      .returns(offline.id => Window.new(start_date: 1.year.ago.to_date, end_date: Date.current))
    balance = accounts(:depository).balances.create!(date: Date.current, balance: 1000, currency: "USD")
    holding = accounts(:investment).holdings.first

    MarketDataResetJob.perform_now

    assert Security::Price.exists?(offline_price.id)
    assert Balance.exists?(balance.id)
    assert Holding.exists?(holding.id)
  end

  test "still imports exchange rates and syncs every account when the price import fails" do
    MarketDataImporter.any_instance.stubs(:import_security_prices).raises(StandardError, "provider down")
    MarketDataImporter.any_instance.expects(:import_exchange_rates).once

    assert_difference -> { DebugLogEntry.where(source: "MarketDataResetJob", level: "error").count }, 1 do
      MarketDataResetJob.perform_now
    end

    assert_enqueued_jobs Account.count, only: SyncJob
  end

  test "enqueue_once queues one reset until it has run" do
    use_own_guard_key
    stub_imports

    assert_enqueued_jobs 1, only: MarketDataResetJob do
      assert_equal :queued, MarketDataResetJob.enqueue_once
      assert_equal :already_queued, MarketDataResetJob.enqueue_once
    end

    MarketDataResetJob.perform_now
    assert_enqueued_jobs 1, only: MarketDataResetJob do
      assert_equal :queued, MarketDataResetJob.enqueue_once
    end
  ensure
    MarketDataResetJob.release_guard
  end

  test "a run that finds another reset running keeps the guard" do
    use_own_guard_key
    stub_imports
    assert_equal :queued, MarketDataResetJob.enqueue_once
    MarketDataResetJob.any_instance.stubs(:with_advisory_lock)

    MarketDataResetJob.perform_now

    assert_equal :already_queued, MarketDataResetJob.enqueue_once
  ensure
    MarketDataResetJob.release_guard
  end

  test "the guard is released after the advisory lock" do
    use_own_guard_key
    stub_imports
    advisory_locks_at_release = []
    MarketDataResetJob.stubs(:release_guard).with do
      advisory_locks_at_release << ActiveRecord::Base.connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()")
      true
    end

    MarketDataResetJob.perform_now

    assert_equal [ 0 ], advisory_locks_at_release
  end

  test "a run that cannot check the advisory lock releases the guard" do
    use_own_guard_key
    assert_equal :queued, MarketDataResetJob.enqueue_once
    MarketDataResetJob.any_instance.stubs(:try_advisory_lock).raises(ActiveRecord::ConnectionNotEstablished)

    assert_raises(ActiveRecord::ConnectionNotEstablished) { MarketDataResetJob.perform_now }

    assert_equal :queued, MarketDataResetJob.enqueue_once
  ensure
    MarketDataResetJob.release_guard
  end

  test "enqueue_once releases the guard when the job cannot be queued" do
    use_own_guard_key
    MarketDataResetJob.stubs(:perform_later).raises(RedisClient::CannotConnectError).then.returns(false).then.returns(MarketDataResetJob.new)

    assert_equal :failed, MarketDataResetJob.enqueue_once
    assert_equal :failed, MarketDataResetJob.enqueue_once
    assert_equal :queued, MarketDataResetJob.enqueue_once
  ensure
    MarketDataResetJob.release_guard
  end

  private
    # Parallel test processes share Redis, so each test guards its own key.
    def use_own_guard_key
      MarketDataResetJob.stubs(:guard_key).returns("market_data_reset_job:test:#{SecureRandom.hex(8)}")
    end

    def stub_imports
      MarketDataImporter.any_instance.stubs(:import_security_prices)
      MarketDataImporter.any_instance.stubs(:import_exchange_rates)
    end
end
