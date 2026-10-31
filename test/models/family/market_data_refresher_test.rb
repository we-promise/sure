require "test_helper"
require "ostruct"

class Family::MarketDataRefresherTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock("provider")
    Provider::Registry.any_instance.stubs(:get_provider).returns(@provider)

    @family = Family.create!(name: "Refresh", currency: "USD")
  end

  test "fetches a currency pair shared by several accounts once and overwrites the stored rates" do
    accounts = 3.times.map do |i|
      @family.accounts.create!(name: "Savings #{i}", currency: "CAD", balance: 100, accountable: Depository.new)
    end
    start_date = accounts.map(&:start_date).min
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: Date.current, rate: 1.0)

    @provider.expects(:fetch_exchange_rates)
             .with(from: "CAD", to: "USD", start_date: anything, end_date: anything)
             .once
             .returns(provider_success_response([
               OpenStruct.new(from: "CAD", to: "USD", date: start_date, rate: 0.73)
             ]))

    Family::MarketDataRefresher.new(@family).refresh

    assert_equal 0.73, ExchangeRate.find_by(from_currency: "CAD", to_currency: "USD", date: Date.current).rate.to_f
  end

  test "downloads the prices of a security held in several accounts once, overwriting stored prices" do
    security = Security.create!(ticker: "RFSH", exchange_operating_mic: "XNAS")
    2.times do |i|
      account = @family.accounts.create!(name: "Brokerage #{i}", currency: "USD", balance: 0, accountable: Investment.new)
      account.holdings.create!(security: security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
    end

    Security.any_instance.expects(:import_provider_prices)
            .with(has_entry(clear_cache: true))
            .once
    Security.any_instance.stubs(:import_provider_details)

    Family::MarketDataRefresher.new(@family).refresh
  end

  test "logs a price refresh the provider reports as failed" do
    security = Security.create!(ticker: "RFSH", exchange_operating_mic: "XNAS")
    account = @family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    account.holdings.create!(security: security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")

    Security.any_instance.expects(:import_provider_prices).returns([ 0, "Rate limit exceeded" ])
    Security.any_instance.stubs(:import_provider_details)

    assert_difference -> { DebugLogEntry.where(family: @family, level: "error").count }, 1 do
      Family::MarketDataRefresher.new(@family).refresh
    end
    assert_match "Rate limit exceeded", DebugLogEntry.where(family: @family).order(:created_at).last.message
  end

  test "logs a pair that fails and goes on with the others" do
    @family.accounts.create!(name: "Savings", currency: "CAD", balance: 100, accountable: Depository.new)
    @family.accounts.create!(name: "Card", currency: "GBP", balance: 100, accountable: CreditCard.new)

    ExchangeRate.expects(:import_provider_rates).with(has_entry(from: "CAD")).raises(StandardError, "provider down")
    ExchangeRate.expects(:import_provider_rates).with(has_entries(from: "GBP", clear_cache: true))

    assert_difference -> { DebugLogEntry.where(family: @family, level: "error").count }, 1 do
      Family::MarketDataRefresher.new(@family).refresh
    end
  end
end
