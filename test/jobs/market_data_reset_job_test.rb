require "test_helper"

class MarketDataResetJobTest < ActiveJob::TestCase
  setup do
    @exchange_rate = exchange_rates(:one)
    @security_price = Security::Price.create!(security: securities(:aapl), date: Date.new(2000, 1, 3), price: 200, currency: "USD")
    ExchangeRate.stubs(:provider).returns(mock("exchange_rate_provider"))
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    Security.stubs(:provider_for).with("twelve_data").returns(mock("securities_provider"))
  end

  test "deletes market data, re-imports it, then syncs every family" do
    sequence = sequence("reset")
    MarketDataImporter.any_instance.expects(:import_security_prices).in_sequence(sequence).with do
      assert_not Security::Price.exists?(@security_price.id), "prices must be gone before the re-import"
      true
    end
    MarketDataImporter.any_instance.expects(:import_exchange_rates).in_sequence(sequence).with do
      assert_not ExchangeRate.exists?(@exchange_rate.id), "rates must be gone before the re-import"
      assert_no_enqueued_jobs only: SyncAllJob
      true
    end

    MarketDataResetJob.perform_now

    assert_enqueued_jobs 1, only: SyncAllJob
  end

  test "keeps account-level data and prices of offline securities" do
    stub_imports
    offline = Security.create!(ticker: "OFFL", name: "Offline Co", offline: true)
    offline_price = offline.prices.create!(date: Date.new(2000, 1, 3), price: 10, currency: "USD")
    balance = accounts(:depository).balances.create!(date: Date.current, balance: 1000, currency: "USD")
    holding = accounts(:investment).holdings.first

    MarketDataResetJob.perform_now

    assert Security::Price.exists?(offline_price.id)
    assert Balance.exists?(balance.id)
    assert Holding.exists?(holding.id)
  end

  test "still imports exchange rates and syncs every family when the price import fails" do
    MarketDataImporter.any_instance.stubs(:import_security_prices).raises(StandardError, "provider down")
    MarketDataImporter.any_instance.expects(:import_exchange_rates).once

    assert_difference -> { DebugLogEntry.where(source: "MarketDataResetJob", level: "error").count }, 1 do
      MarketDataResetJob.perform_now
    end

    assert_enqueued_jobs 1, only: SyncAllJob
  end

  test "keeps data that no configured provider can fetch again" do
    stub_imports
    ExchangeRate.stubs(:provider).returns(nil)
    Security.stubs(:provider_for).with("twelve_data").returns(nil)

    MarketDataResetJob.perform_now

    assert ExchangeRate.exists?(@exchange_rate.id)
    assert Security::Price.exists?(@security_price.id)
  end

  test "keeps prices of securities whose assigned provider is unavailable" do
    stub_imports
    other = Security.create!(ticker: "MFX", name: "Other provider", price_provider: nil)
    other_price = other.prices.create!(date: Date.new(2000, 1, 3), price: 5, currency: "USD")
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data", "mfapi" ])
    Security.stubs(:provider_for).with("mfapi").returns(nil)
    securities(:aapl).update_column(:price_provider, "mfapi")

    MarketDataResetJob.perform_now

    assert Security::Price.exists?(@security_price.id), "assigned provider unavailable"
    assert_not Security::Price.exists?(other_price.id), "unassigned security falls back to an enabled provider"
  end

  private
    def stub_imports
      MarketDataImporter.any_instance.stubs(:import_security_prices)
      MarketDataImporter.any_instance.stubs(:import_exchange_rates)
    end
end
