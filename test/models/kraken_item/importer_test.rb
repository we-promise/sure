# frozen_string_literal: true

require "test_helper"

class KrakenItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = KrakenItem.create!(
      family: @family,
      name: "Kraken",
      api_key: "k",
      api_secret: "s"
    )
    @provider = mock
    @provider.stubs(:get_api_key_info).returns({ "name" => "Sure read-only" })
    @provider.stubs(:get_asset_pairs).returns(pair_metadata)
    @provider.stubs(:get_trades_history).returns({ "count" => 0, "trades" => {} })
    @provider.stubs(:get_ticker).returns(nil)
  end

  test "creates a combined kraken account from BalanceEx" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "XXBT" => { "balance" => "1.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0.25" },
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })

    assert_difference "@item.kraken_accounts.count", 1 do
      KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    end

    account = @item.kraken_accounts.first
    assert_equal "combined", account.account_id
    assert_equal "combined", account.account_type
    assert_equal "USD", account.currency
    assert_in_delta 50_050, account.current_balance, 0.01

    btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" }
    assert_equal "0.75", btc["available"]
    assert_equal "0.25", btc["hold_trade"]
  end

  test "preserves suffix assets in metadata and marks missing prices" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "XETH.F" => { "balance" => "2.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )

    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    account = @item.kraken_accounts.first
    eth = account.raw_payload["assets"].first
    assert_equal "ETH.F", eth["symbol"]
    assert_equal "ETH", eth["price_symbol"]
    assert_equal ".F", eth["suffix"]
    assert_equal "missing", eth["price_status"]
    assert_includes account.extra.dig("kraken", "missing_prices"), "ETH.F"
  end

  test "paginates TradesHistory in 50 fill pages" do
    @provider.stubs(:get_asset_info).returns({})
    @provider.stubs(:get_extended_balance).returns({})
    first_page = 50.times.to_h { |i| [ "tx#{i}", trade_payload("tx#{i}") ] }
    second_page = { "tx50" => trade_payload("tx50") }

    @provider.expects(:get_trades_history).with(start: nil, offset: 0).returns({ "count" => 51, "trades" => first_page })
    @provider.expects(:get_trades_history).with(start: nil, offset: 50).returns({ "count" => 51, "trades" => second_page })

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    assert_equal 51, result[:trades_imported]
    assert_equal 51, @item.kraken_accounts.first.raw_transactions_payload["trades"].size
  end

  test "marks item requires_update when required endpoint reports permission error" do
    @provider.stubs(:get_asset_info).returns({})
    @provider.stubs(:get_asset_pairs).returns({})
    @provider.stubs(:get_extended_balance).raises(Provider::Kraken::PermissionError, "EGeneral:Permission denied")

    assert_raises(Provider::Kraken::PermissionError) do
      KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    end

    assert @item.reload.requires_update?
  end

  private

    def asset_metadata
      {
        "XXBT" => { "altname" => "XBT" },
        "XETH" => { "altname" => "ETH" },
        "ZUSD" => { "altname" => "USD" }
      }
    end

    def pair_metadata
      {
        "XXBTZUSD" => { "altname" => "XBTUSD", "base" => "XXBT", "quote" => "ZUSD" }
      }
    end

    def trade_payload(txid)
      {
        "ordertxid" => "order_#{txid}",
        "pair" => "XBTUSD",
        "time" => Time.current.to_f,
        "type" => "buy",
        "price" => "50000.0",
        "cost" => "50.0",
        "fee" => "0.1",
        "vol" => "0.001"
      }
    end
end
