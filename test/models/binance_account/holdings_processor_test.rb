# frozen_string_literal: true

require "test_helper"

class BinanceAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "EUR")

    @item = BinanceItem.create!(
      family: @family, name: "Binance", api_key: "k", api_secret: "s"
    )
    @ba = @item.binance_accounts.create!(
      name: "Binance",
      account_type: "combined",
      currency: "USD",
      current_balance: 1000,
      raw_payload: {
        "assets" => [ { "symbol" => "BTC", "total" => "0.5", "source" => "spot" } ]
      }
    )
    @account = Account.create!(
      family: @family,
      name: "Binance",
      balance: 0,
      currency: "EUR",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)
  end

  test "converts holding amount to family currency when exact rate exists" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end

    BinanceAccount::AssetPricer.any_instance
      .stubs(:live_price_usd).with("BTC").returns(60_000.0)

    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(currency: "EUR", amount: 27_600.0)
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BinanceAccount::HoldingsProcessor.new(@ba).process
  end

  test "uses raw USD amount when no rate is available" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end

    BinanceAccount::AssetPricer.any_instance
      .stubs(:live_price_usd).with("BTC").returns(60_000.0)

    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(currency: "EUR", amount: 30_000.0)
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BinanceAccount::HoldingsProcessor.new(@ba).process
  end
  # The reported bug. The processor wrote whatever Binance returned and never
  # removed what it stopped returning, so an asset sold between two syncs kept
  # its row for the day — and the account page reads exactly that day.
  test "an asset that has left the wallet stops being held" do
    seed_rate_and_securities

    write_payload([ btc_asset, eth_asset ])
    BinanceAccount::HoldingsProcessor.new(@ba).process
    assert_equal [ "CRYPTO:BTC", "CRYPTO:ETH" ], held_tickers

    # ETH is sold, so Binance stops returning it.
    write_payload([ btc_asset ])
    BinanceAccount::HoldingsProcessor.new(@ba).process

    assert_equal [ "CRYPTO:BTC" ], held_tickers,
                 "an asset the wallet no longer holds was still in the portfolio"
  end

  # An emptied wallet is the same question with nothing left to compare
  # against, and the early return on a blank asset list skipped the removal
  # entirely.
  test "emptying the wallet empties the portfolio" do
    seed_rate_and_securities

    write_payload([ btc_asset ])
    BinanceAccount::HoldingsProcessor.new(@ba).process
    assert_equal [ "CRYPTO:BTC" ], held_tickers

    write_payload([])
    BinanceAccount::HoldingsProcessor.new(@ba).process

    assert_empty held_tickers, "the emptied wallet still reported holdings"
  end

  test "keeps wrapped and unwrapped assets as separate holdings" do
    seed_rate_and_securities
    write_payload([ eth_asset, { "symbol" => "WETH", "total" => "3", "source" => "spot" } ])

    BinanceAccount::HoldingsProcessor.new(@ba).process

    holdings = @account.reload.current_holdings.index_by { |holding| holding.security.ticker }
    assert_equal 2, holdings.fetch("CRYPTO:ETH").qty
    assert_equal 3, holdings.fetch("CRYPTO:WETH").qty
  end

  test "keeps reported units when no market quote exists" do
    seed_rate_and_securities
    write_payload([ eth_asset ])
    BinanceAccount::AssetPricer.any_instance.stubs(:live_price_usd).with("ETH").returns(nil)

    BinanceAccount::HoldingsProcessor.new(@ba).process

    holding = @account.holdings.find_by!(security: Security.find_by!(ticker: "CRYPTO:ETH"), date: Date.current)
    assert_equal eth_asset.fetch("total").to_d, holding.qty
    assert_equal 0, holding.price
    assert DebugLogEntry.where(provider_key: "binance").exists?
  end

  test "keeps reported units when the cached quote currency is unknown" do
    seed_rate_and_securities
    write_payload([ eth_asset ])
    security = Security.find_by!(ticker: "CRYPTO:ETH")
    security.prices.create!(date: Date.current, price: 2000, currency: "INVALID")
    BinanceAccount::AssetPricer.any_instance.stubs(:live_price_usd).with("ETH").returns(nil)

    BinanceAccount::HoldingsProcessor.new(@ba).process

    holding = @account.holdings.find_by!(security: security, date: Date.current)
    assert_equal eth_asset.fetch("total").to_d, holding.qty
    assert_equal 0, holding.price
    assert_equal 0, holding.amount
  end

  test "reuses the last known price during a quote outage" do
    seed_rate_and_securities
    write_payload([ eth_asset ])
    security = Security.find_by!(ticker: "CRYPTO:ETH")
    security.prices.create!(date: Date.current, price: 2000, currency: "USD")
    BinanceAccount::AssetPricer.any_instance.stubs(:live_price_usd).with("ETH").returns(nil)

    BinanceAccount::HoldingsProcessor.new(@ba).process

    holding = @account.holdings.find_by!(security: security, date: Date.current)
    assert_equal eth_asset.fetch("total").to_d, holding.qty
    assert_equal 2000, holding.price
  end

  test "an unpriced zero placeholder does not hide an older usable quote" do
    seed_rate_and_securities
    write_payload([ eth_asset ])
    security = Security.find_by!(ticker: "CRYPTO:ETH")
    security.prices.create!(date: Date.current - 1.day, price: 2000, currency: "USD")
    security.prices.create!(date: Date.current, price: 0, currency: "USD")
    BinanceAccount::AssetPricer.any_instance.stubs(:live_price_usd).with("ETH").returns(nil)

    BinanceAccount::HoldingsProcessor.new(@ba).process

    assert_equal 2000, @account.holdings.find_by!(security: security, date: Date.current).price
  end

  test "sums an asset held in several wallets into one holding" do
    seed_rate_and_securities
    write_payload([ btc_asset, { "symbol" => "BTC", "total" => "0.25", "source" => "funding" }, eth_asset ])

    BinanceAccount::HoldingsProcessor.new(@ba).process

    holding = @account.holdings.find_by!(security: Security.find_by!(ticker: "CRYPTO:BTC"), date: Date.current)
    assert_equal 0.75, holding.qty
    assert_equal 750, holding.amount
    assert_equal "binance_BTC_funding+spot_#{Date.current}", holding.external_id
    assert_equal [ "CRYPTO:BTC", "CRYPTO:ETH" ], held_tickers
  end

  test "values holdings with the quotes behind the account total" do
    seed_rate_and_securities
    quotes = { "ETH" => { "price_usd" => "1500", "date" => (Date.current - 2.days).iso8601 } }
    @ba.update!(raw_payload: { "assets" => [ eth_asset, btc_asset ], "quotes" => quotes })
    BinanceAccount::AssetPricer.any_instance.expects(:live_price_usd).never

    BinanceAccount::HoldingsProcessor.new(@ba).process

    eth = @account.holdings.find_by!(security: Security.find_by!(ticker: "CRYPTO:ETH"), date: Date.current)
    btc = @account.holdings.find_by!(security: Security.find_by!(ticker: "CRYPTO:BTC"), date: Date.current)
    assert_equal 1500, eth.price
    assert_equal 0, btc.price, "an asset the total left unpriced was valued anyway"
    assert_equal 0.5, btc.qty
    assert_equal 2, DebugLogEntry.where(provider_key: "binance").count
  end

  private
    def seed_rate_and_securities
      ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                           date: Date.current, rate: 1.0)
      %w[BTC ETH].each do |symbol|
        Security.find_or_create_by!(ticker: "CRYPTO:#{symbol}") do |s|
          s.name = symbol
          s.exchange_operating_mic = "XBNC"
        end
      end
      BinanceAccount::AssetPricer.any_instance.stubs(:live_price_usd).returns(1_000.0)
    end

    def btc_asset = { "symbol" => "BTC", "total" => "0.5", "source" => "spot" }
    def eth_asset = { "symbol" => "ETH", "total" => "2", "source" => "spot" }

    def write_payload(assets)
      @ba.update!(raw_payload: { "assets" => assets })
    end

    def held_tickers
      @account.reload.current_holdings.filter_map { |h| h.security&.ticker }.sort
    end
end
