# frozen_string_literal: true

require "test_helper"

class RevolutXItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = families(:dylan_family).revolut_x_items.create!(name: "Revolut X", api_key: "a1" * 32)
    @provider = mock
    @provider.stubs(:get_balances).returns(payload("balances"))
    @provider.stubs(:get_sub_accounts).returns(payload("sub_accounts"))
    @provider.stubs(:get_currencies).returns(
      payload("currencies").merge("USD" => { "symbol" => "USD", "name" => "US Dollar", "scale" => 2, "asset_type" => "fiat", "status" => "active" })
    )
    @tickers = payload("tickers")
    @tickers["data"] << { "symbol" => "ETH/USD", "mid" => "3000.00", "last_price" => "2999.00" }
    @provider.stubs(:get_tickers).returns(@tickers)
  end

  test "stores one USD account valued from balances and tickers" do
    assert_difference -> { @item.revolut_x_accounts.count }, 1 do
      import
    end

    account = @item.revolut_x_accounts.sole
    assert_equal "default", account.account_id
    assert_equal "exchange", account.account_type
    assert_equal "USD", account.currency
    assert_equal "Revolut X", account.name
    assert_equal (1.35.to_d * 120_000) + (42 * 3000) + 5500.50.to_d, account.current_balance

    @item.reload
    assert_equal payload("balances"), @item.raw_payload["balances"]
    assert_equal payload("sub_accounts").dig("data", "sub_accounts"), @item.raw_payload["sub_accounts"]
    assert_equal "fiat", @item.raw_payload.dig("currencies", "USD", "asset_type")
  end

  test "a second import updates the same account" do
    import
    @provider.stubs(:get_balances).returns([ { "currency" => "USD", "total" => "10" } ])

    assert_no_difference -> { @item.revolut_x_accounts.count } do
      import
    end
    assert_equal 10, @item.revolut_x_accounts.sole.current_balance
  end

  test "falls back to last_price, then to a EUR or GBP pair converted to USD" do
    @tickers["data"] = [
      { "symbol" => "BTC/USD", "mid" => "", "last_price" => "100000.00" },
      { "symbol" => "ETH/GBP", "mid" => "2000.00" }
    ]
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: Date.current, rate: 1.25)

    import

    assets = @item.revolut_x_accounts.sole.raw_payload["assets"].index_by { |asset| asset["symbol"] }
    assert_equal "100000.0", assets["BTC"]["price_usd"]
    assert_equal "2500.0", assets["ETH"]["price_usd"]
  end

  test "keeps an unpriced asset with no price and no value" do
    @tickers["data"].reject! { |ticker| ticker["symbol"].start_with?("ETH/") }

    import

    account = @item.revolut_x_accounts.sole
    eth = account.raw_payload["assets"].find { |asset| asset["symbol"] == "ETH" }
    assert_nil eth["price_usd"]
    assert_equal (1.35.to_d * 120_000) + 5500.50.to_d, account.current_balance
  end

  private

    def import
      RevolutXItem::Importer.new(@item, revolut_x_provider: @provider).import
    end

    def payload(name)
      JSON.parse(file_fixture("revolut_x/#{name}.json").read)
    end
end
