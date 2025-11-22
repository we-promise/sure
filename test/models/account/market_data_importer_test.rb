require "test_helper"
require "ostruct"

class Account::MarketDataImporterTest < ActiveSupport::TestCase
  include ProviderTestHelper

  PROVIDER_BUFFER = 5.days

  setup do
    # Ensure a clean slate for deterministic assertions
    Security::Price.delete_all
    ExchangeRate.delete_all
    Trade.delete_all
    Holding.delete_all
    Security.delete_all
    Entry.delete_all

    @provider = mock("provider")
    Provider::Registry.any_instance
                      .stubs(:get_provider)
                      .with(:twelve_data)
                      .returns(@provider)
  end

  test "syncs required exchange rates for a foreign-currency account" do
    family = Family.create!(name: "Smith", currency: "USD")

    account = family.accounts.create!(
      name: "Chequing",
      currency: "CAD",
      balance: 100,
      accountable: Depository.new
    )

    # Seed a rate for the first required day so that the importer only needs the next day forward
    existing_date = account.start_date
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: existing_date, rate: 2.0)
    ExchangeRate.create!(from_currency: "USD", to_currency: "CAD", date: existing_date, rate: 0.5)

    expected_start_date = (existing_date + 1.day) - PROVIDER_BUFFER
    end_date            = Date.current.in_time_zone("America/New_York").to_date

    @provider.expects(:fetch_exchange_rates)
             .with(from: "CAD",
                   to: "USD",
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_success_response([
               OpenStruct.new(from: "CAD", to: "USD", date: existing_date, rate: 1.5)
             ]))

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD",
                   to: "CAD",
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_success_response([
               OpenStruct.new(from: "USD", to: "CAD", date: existing_date, rate: 0.67)
             ]))

    before = ExchangeRate.count
    Account::MarketDataImporter.new(account).import_all
    after  = ExchangeRate.count

    assert_operator after, :>, before + 1, "Should insert at least two new exchange-rate rows"
  end

  test "syncs security prices for securities traded by the account" do
    family = Family.create!(name: "Smith", currency: "USD")

    account = family.accounts.create!(
      name: "Brokerage",
      currency: "USD",
      balance: 0,
      accountable: Investment.new
    )

    security = Security.create!(ticker: "AAPL", exchange_operating_mic: "XNAS")

    trade_date = 10.days.ago.to_date
    trade      = Trade.new(security: security, qty: 1, price: 100, currency: "USD")

    account.entries.create!(
      name: "Buy AAPL",
      date: trade_date,
      amount: 100,
      currency: "USD",
      entryable: trade
    )

    expected_start_date = trade_date - PROVIDER_BUFFER
    end_date            = Date.current.in_time_zone("America/New_York").to_date

    @provider.expects(:fetch_security_prices)
             .with(symbol: security.ticker,
                   exchange_operating_mic: security.exchange_operating_mic,
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_success_response([
               OpenStruct.new(security: security,
                              date: trade_date,
                              price: 100,
                              currency: "USD")
             ]))

    @provider.stubs(:fetch_security_info)
             .with(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic)
             .returns(provider_success_response(OpenStruct.new(name: "Apple", logo_url: "logo")))

    # Ignore exchange-rate calls for this test
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([]))

    Account::MarketDataImporter.new(account).import_all

    assert_equal 1, Security::Price.where(security: security, date: trade_date).count
  end

  test "handles provider error response gracefully for security prices" do
    family = Family.create!(name: "Smith", currency: "USD")

    account = family.accounts.create!(
      name: "Brokerage",
      currency: "USD",
      balance: 0,
      accountable: Investment.new
    )

    security = Security.create!(ticker: "INVALID", exchange_operating_mic: "XNAS")

    trade_date = 10.days.ago.to_date
    trade      = Trade.new(security: security, qty: 1, price: 100, currency: "USD")

    account.entries.create!(
      name: "Buy INVALID",
      date: trade_date,
      amount: 100,
      currency: "USD",
      entryable: trade
    )

    expected_start_date = trade_date - PROVIDER_BUFFER
    end_date            = Date.current.in_time_zone("America/New_York").to_date

    # Simulate provider returning an error response
    @provider.expects(:fetch_security_prices)
             .with(symbol: security.ticker,
                   exchange_operating_mic: security.exchange_operating_mic,
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_error_response(
               Provider::TwelveData::Error.new("Invalid symbol", details: { code: 400, message: "Invalid symbol" })
             ))

    @provider.stubs(:fetch_security_info)
             .with(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic)
             .returns(provider_success_response(OpenStruct.new(name: "Invalid Co", logo_url: "logo")))

    # Ignore exchange-rate calls for this test
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([]))

    # Should not raise an error, just log and continue
    assert_nothing_raised do
      Account::MarketDataImporter.new(account).import_all
    end

    assert_equal 0, Security::Price.where(security: security, date: trade_date).count
  end

  test "handles provider error response gracefully for exchange rates" do
    family = Family.create!(name: "Smith", currency: "USD")

    account = family.accounts.create!(
      name: "Chequing",
      currency: "CAD",
      balance: 100,
      accountable: Depository.new
    )

    # Seed a rate for the first required day
    existing_date = account.start_date
    ExchangeRate.create!(from_currency: "CAD", to_currency: "USD", date: existing_date, rate: 2.0)
    ExchangeRate.create!(from_currency: "USD", to_currency: "CAD", date: existing_date, rate: 0.5)

    expected_start_date = (existing_date + 1.day) - PROVIDER_BUFFER
    end_date            = Date.current.in_time_zone("America/New_York").to_date

    # Simulate provider returning an error response
    @provider.expects(:fetch_exchange_rates)
             .with(from: "CAD",
                   to: "USD",
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_error_response(
               Provider::TwelveData::Error.new("Rate limit exceeded", details: { code: 429, message: "Rate limit exceeded" })
             ))

    @provider.expects(:fetch_exchange_rates)
             .with(from: "USD",
                   to: "CAD",
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_error_response(
               Provider::TwelveData::Error.new("Rate limit exceeded", details: { code: 429, message: "Rate limit exceeded" })
             ))

    before = ExchangeRate.count

    # Should not raise an error, just log and continue
    assert_nothing_raised do
      Account::MarketDataImporter.new(account).import_all
    end

    after = ExchangeRate.count

    # No new rates should be added due to error
    assert_equal before, after
  end
end
