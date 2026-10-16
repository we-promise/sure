require "test_helper"
require "ostruct"

class MarketDataImporterTest < ActiveSupport::TestCase
  include ProviderTestHelper

  SNAPSHOT_START_DATE       = MarketDataImporter::SNAPSHOT_DAYS.days.ago.to_date
  SECURITY_PRICE_BUFFER     = Security::Price::Importer::PROVISIONAL_LOOKBACK_DAYS.days
  EXCHANGE_RATE_BUFFER      = 5.days

  setup do
    Security::Price.delete_all
    ExchangeRate.delete_all
    Trade.delete_all
    Holding.delete_all
    Security.delete_all

    @provider = mock("provider")
    Provider::Registry.any_instance
                      .stubs(:get_provider)
                      .with(:twelve_data)
                      .returns(@provider)
  end

  test "syncs required exchange rates" do
    family = Family.create!(name: "Smith", currency: "USD")
    family.accounts.create!(name: "Chequing",
                            currency: "CAD",
                            balance: 100,
                            accountable: Depository.new)

    # Seed stale rate so only the next missing day is fetched
    ExchangeRate.create!(from_currency: "CAD",
                         to_currency: "USD",
                         date: SNAPSHOT_START_DATE,
                         rate: 2.0)

    ExchangeRate.create!(from_currency: "USD",
                         to_currency: "CAD",
                         date: SNAPSHOT_START_DATE,
                         rate: 0.5)

    expected_start_date = (SNAPSHOT_START_DATE + 1.day) - EXCHANGE_RATE_BUFFER
    end_date            = Date.current.in_time_zone("America/New_York").to_date

    # Only the forward pair (CAD→USD) should be fetched; inverse (USD→CAD) is computed automatically
    @provider.expects(:fetch_exchange_rates)
             .with(from: "CAD",
                   to: "USD",
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_success_response([
               OpenStruct.new(from: "CAD", to: "USD", date: SNAPSHOT_START_DATE, rate: 1.5)
             ]))

    before = ExchangeRate.count
    MarketDataImporter.new(mode: :snapshot).import_exchange_rates
    after  = ExchangeRate.count

    assert_operator after, :>, before + 1, "Should insert at least two new exchange-rate rows (forward + computed inverse)"
  end

  test "syncs account exchange rates into the primary currency when the family currency is blank or NULL" do
    blank_family = Family.create!(name: "Blank", currency: "")
    null_family = Family.create!(name: "Null", currency: "USD")
    null_family.update_column(:currency, nil)

    [ blank_family, null_family ].each do |family|
      family.accounts.create!(name: "Chequing", currency: "CAD", balance: 100, accountable: Depository.new)
      family.accounts.create!(name: "Savings", currency: "USD", balance: 100, accountable: Depository.new)
    end

    # One CAD→USD fetch covers both families; the USD accounts already match the
    # USD fallback and need no rates.
    @provider.expects(:fetch_exchange_rates)
             .with(from: "CAD", to: "USD", start_date: anything, end_date: anything)
             .once
             .returns(provider_success_response([]))

    MarketDataImporter.new(mode: :snapshot).import_exchange_rates
  end

  test "syncs foreign entry currencies against the family currency as well as the account currency" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Chequing", currency: "CAD", balance: 100, accountable: Depository.new)
    account.entries.create!(date: 10.days.ago.to_date, amount: 10, currency: "GBP", name: "Card payment", entryable: Transaction.new)

    [ %w[GBP CAD], %w[GBP USD], %w[CAD USD] ].each do |from, to|
      @provider.expects(:fetch_exchange_rates)
               .with(from: from, to: to, start_date: anything, end_date: anything)
               .once
               .returns(provider_success_response([]))
    end

    MarketDataImporter.new(mode: :snapshot).import_exchange_rates
  end

  test "syncs security prices" do
    security = Security.create!(ticker: "AAPL", exchange_operating_mic: "XNAS")
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    trade = Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy")
    account.entries.create!(name: "Buy AAPL", date: 40.days.ago.to_date, amount: 100, currency: "USD", entryable: trade)
    account.holdings.create!(security: security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")

    expected_start_date = SNAPSHOT_START_DATE - SECURITY_PRICE_BUFFER
    end_date            = Date.current.in_time_zone("America/New_York").to_date

    @provider.expects(:fetch_security_prices)
             .with(symbol: security.ticker,
                   exchange_operating_mic: security.exchange_operating_mic,
                   start_date: expected_start_date,
                   end_date: end_date)
             .returns(provider_success_response([
               OpenStruct.new(security: security,
                              date: SNAPSHOT_START_DATE,
                              price: 100,
                              currency: "USD")
             ]))

    @provider.stubs(:fetch_security_info)
             .with(symbol: "AAPL", exchange_operating_mic: "XNAS")
             .returns(provider_success_response(OpenStruct.new(name: "Apple", logo_url: "logo")))

    # Ignore exchange rate calls for this test
    @provider.stubs(:fetch_exchange_rates).returns(provider_success_response([]))

    MarketDataImporter.new(mode: :snapshot).import_security_prices

    assert_equal 1, Security::Price.where(security: security, date: SNAPSHOT_START_DATE).count
  end

  test "fetches no prices for online securities without holdings or trades" do
    security = Security.create!(ticker: "UNUSED", exchange_operating_mic: "XNAS")

    @provider.expects(:fetch_security_prices).never
    @provider.expects(:fetch_security_info)
             .with(symbol: "UNUSED", exchange_operating_mic: "XNAS")
             .once
             .returns(provider_success_response(OpenStruct.new(name: "Unused", logo_url: "logo")))

    MarketDataImporter.new(mode: :full).import_security_prices

    assert_equal "Unused", security.reload.name
  end

  test "stops the global price range at a sale despite zero holdings through today" do
    security = Security.create!(ticker: "HIST", exchange_operating_mic: "XNAS")
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    buy_date = 30.days.ago.to_date
    sell_date = 5.days.ago.to_date

    account.entries.create!(name: "Buy", date: buy_date, amount: 100, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    account.entries.create!(name: "Sell", date: sell_date, amount: 110, currency: "USD",
                            entryable: Trade.new(security: security, qty: -1, price: 110, currency: "USD", investment_activity_label: "Sell"))
    account.holdings.create!(security: security, date: sell_date - 1.day, qty: 1, price: 105, amount: 105, currency: "USD")
    account.holdings.create!(security: security, date: sell_date, qty: 0, price: 105, amount: 0, currency: "USD")
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 105, amount: 0, currency: "USD")

    @provider.expects(:fetch_security_prices)
             .with(symbol: "HIST", exchange_operating_mic: "XNAS",
                   start_date: buy_date - SECURITY_PRICE_BUFFER, end_date: sell_date)
             .once
             .returns(provider_success_response([]))
    @provider.stubs(:fetch_security_info).returns(provider_success_response(OpenStruct.new(name: "Historic", logo_url: "logo")))

    MarketDataImporter.new(mode: :full).import_security_prices
  end

  test "does not refetch a complete sold position on later daily imports" do
    security = Security.create!(ticker: "CLOSED", exchange_operating_mic: "XNAS")
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    buy_date = 12.days.ago.to_date
    sell_date = 5.days.ago.to_date

    account.entries.create!(name: "Buy", date: buy_date, amount: 100, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    account.entries.create!(name: "Sell", date: sell_date, amount: 110, currency: "USD",
                            entryable: Trade.new(security: security, qty: -1, price: 110, currency: "USD", investment_activity_label: "Sell"))
    account.holdings.create!(security: security, date: sell_date - 1.day, qty: 1, price: 105, amount: 105, currency: "USD")
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 105, amount: 0, currency: "USD")

    (buy_date..sell_date).each do |date|
      Security::Price.create!(security: security, date: date, price: 100, currency: "USD", provisional: false)
    end

    @provider.expects(:fetch_security_prices).never
    @provider.stubs(:fetch_security_info).returns(provider_success_response(OpenStruct.new(name: "Closed", logo_url: "logo")))

    2.times { MarketDataImporter.new(mode: :full).import_security_prices }
  end

  test "snapshot cache clearing skips a position closed before the snapshot" do
    security = Security.create!(ticker: "OLD", exchange_operating_mic: "XNAS")
    account = Family.create!(name: "Smith", currency: "USD").accounts.create!(
      name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new
    )
    buy_date = 90.days.ago.to_date
    sell_date = 60.days.ago.to_date

    account.entries.create!(name: "Buy", date: buy_date, amount: 100, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    account.entries.create!(name: "Sell", date: sell_date, amount: 110, currency: "USD",
                            entryable: Trade.new(security: security, qty: -1, price: 110, currency: "USD", investment_activity_label: "Sell"))
    account.holdings.create!(security: security, date: sell_date - 1.day, qty: 1, price: 105, amount: 105, currency: "USD")
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 110, amount: 0, currency: "USD")

    @provider.expects(:fetch_security_prices).never
    @provider.stubs(:fetch_security_info).returns(provider_success_response(OpenStruct.new(name: "Old", logo_url: "logo")))

    MarketDataImporter.new(mode: :snapshot, clear_cache: true).import_security_prices
  end

  test "keeps a shared security current while another account holds it" do
    security = Security.create!(ticker: "SHARED", exchange_operating_mic: "XNAS")
    first_family = Family.create!(name: "First", currency: "USD")
    second_family = Family.create!(name: "Second", currency: "USD")
    sold_account = first_family.accounts.create!(name: "Sold", currency: "USD", balance: 0, accountable: Investment.new)
    open_account = second_family.accounts.create!(name: "Open", currency: "USD", balance: 0, accountable: Investment.new)
    first_buy = 40.days.ago.to_date

    sold_account.entries.create!(name: "Buy", date: first_buy, amount: 100, currency: "USD",
                                 entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    sold_account.entries.create!(name: "Sell", date: 5.days.ago.to_date, amount: 110, currency: "USD",
                                 entryable: Trade.new(security: security, qty: -1, price: 110, currency: "USD", investment_activity_label: "Sell"))
    sold_account.holdings.create!(security: security, date: Date.current, qty: 0, price: 110, amount: 0, currency: "USD")
    open_account.holdings.create!(security: security, date: Date.current, qty: 1, price: 120, amount: 120, currency: "USD")

    @provider.expects(:fetch_security_prices)
             .with(symbol: "SHARED", exchange_operating_mic: "XNAS",
                   start_date: first_buy - SECURITY_PRICE_BUFFER,
                   end_date: Date.current.in_time_zone("America/New_York").to_date)
             .once
             .returns(provider_success_response([]))
    @provider.stubs(:fetch_security_info).returns(provider_success_response(OpenStruct.new(name: "Shared", logo_url: "logo")))

    MarketDataImporter.new(mode: :full).import_security_prices
  end
end
