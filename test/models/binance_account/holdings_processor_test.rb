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

  test "converts holding amount to account currency when exact rate exists" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end

    BinanceAccount::HoldingsProcessor.any_instance
      .stubs(:fetch_price).with("BTC").returns(60_000.0)

    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(currency: "EUR", amount: 27_600.0)
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BinanceAccount::HoldingsProcessor.new(@ba).process
  end

  test "does not import an unconverted holding when no rate is available" do
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBNC"
    end

    BinanceAccount::HoldingsProcessor.any_instance
      .stubs(:fetch_price).with("BTC").returns(60_000.0)

    import_adapter = mock
    import_adapter.expects(:import_holding).never
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BinanceAccount::HoldingsProcessor.new(@ba).process
    assert_empty @account.holdings
  end

  test "preserves an existing holding when its new value cannot be converted" do
    seed_rate_and_securities
    BinanceAccount::HoldingsProcessor.new(@ba).process
    holding = @account.holdings.sole
    previous = holding.attributes.slice("qty", "price", "amount", "currency")
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)
    write_payload([ btc_asset.merge("total" => "2") ])

    BinanceAccount::HoldingsProcessor.new(@ba).process

    assert_equal previous, holding.reload.attributes.slice("qty", "price", "amount", "currency")
    assert_equal 1, @account.holdings.count
  end

  test "keeps holding values in the linked USD account currency" do
    @account.update!(currency: "USD")
    ExchangeRate.expects(:find_or_fetch_rate).never
    security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XBNC")
    BinanceAccount::SecurityResolver.stubs(:resolve).returns(security)
    BinanceAccount::HoldingsProcessor.any_instance.stubs(:fetch_price).with("BTC").returns(60_000.to_d)
    adapter = mock
    adapter.expects(:import_holding).with(has_entries(currency: "USD", amount: 30_000.to_d, price: 60_000.to_d))
    Account::ProviderImportAdapter.stubs(:new).returns(adapter)

    BinanceAccount::HoldingsProcessor.new(@ba).process
    assert_equal "EUR", @family.reload.currency
    assert_equal "USD", @account.reload.currency
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

  test "invalid prices preserve existing holdings and a valid alternate quote refreshes them" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 1)
    security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XBNC")
    BinanceAccount::SecurityResolver.stubs(:resolve).returns(security)
    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_spot_price).returns("1000")
    BinanceAccount::HoldingsProcessor.new(@ba).process
    holding = @account.holdings.sole
    previous = holding.attributes.slice("qty", "price", "amount", "currency")
    write_payload([ btc_asset.merge("total" => "2") ])

    [ "0", "-1", "NaN", "Infinity", "bad", nil ].each do |price|
      provider.stubs(:get_spot_price).returns(price)
      BinanceAccount::HoldingsProcessor.new(@ba).process
      assert_equal previous, holding.reload.attributes.slice("qty", "price", "amount", "currency")
    end

    provider.expects(:get_spot_price).with("BTCUSDT").returns("0")
    provider.expects(:get_spot_price).with("BTCBUSD").raises(StandardError, "unavailable")
    provider.expects(:get_spot_price).with("BTCFDUSD").returns("1200")
    BinanceAccount::HoldingsProcessor.new(@ba).process
    assert_equal 2400.to_d, holding.reload.amount
    assert_equal 1200.to_d, holding.price
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
      BinanceAccount::HoldingsProcessor.any_instance.stubs(:fetch_price).returns(1_000.0)
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
