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
    @provider.stubs(:get_ledgers).returns({ "ledger" => {}, "count" => 0 })
    @provider.stubs(:get_ticker).returns(nil)
    @provider.stubs(:get_earn_allocations).returns({ "items" => [] })
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

  test "merges Earn allocated balances alongside spot assets" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [
        {
          "native_asset" => "XXBT",
          "amount_allocated" => { "total" => { "native" => "2.0", "converted" => "100000.0" } }
        }
      ]
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })

    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    account = @item.kraken_accounts.first
    earn_btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" && asset["source"] == "earn" }
    assert_not_nil earn_btc
    assert_equal "2.0", earn_btc["balance"]
    assert_equal "0", earn_btc["available"]
    assert_in_delta 100_000, earn_btc["amount_usd"].to_f, 0.01
    assert_in_delta 150_050, account.current_balance, 0.01
  end

  test "degrades gracefully when Earn Allocations permission is denied" do
    @provider.stubs(:get_asset_info).returns({})
    @provider.stubs(:get_extended_balance).returns({})
    @provider.stubs(:get_earn_allocations).raises(Provider::Kraken::PermissionError, "EGeneral:Permission denied")

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]
  end

  test "degrades gracefully when Earn Allocations is rate limited" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    # RateLimitError is a sibling of ApiError (both < Provider::Kraken::Error),
    # not a subclass, so it must be rescued explicitly here or it propagates
    # out of #import and aborts the whole sync -- including the spot balance
    # that already succeeded -- over a transient, Earn-specific rate limit.
    @provider.stubs(:get_earn_allocations).raises(Provider::Kraken::RateLimitError, "Rate limit exceeded")

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    assert_in_delta 50.0, account.current_balance, 0.01
  end

  test "carries forward last known Earn assets when a later sync's fetch fails" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [
        { "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "2.0" } } }
      ]
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })
    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    # A transient failure on the next sync -- even one that only shows up on a
    # later cursor page -- must not erase the principal a previous successful
    # sync already saw.
    @provider.stubs(:get_earn_allocations).raises(Provider::Kraken::ApiError, "EGeneral:Internal error")

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    earn_btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" && asset["source"] == "earn" }
    assert_not_nil earn_btc, "expected the previously-seen Earn BTC position to be carried forward"
    assert_equal "2.0", earn_btc["balance"]
  end

  test "carries forward last known Earn assets rather than saving an undercount when one item is malformed" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [
        { "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "2.0" } } }
      ]
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })
    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    # The next sync returns one good item and one with an unexpected shape
    # (amount_allocated is a bare string, not the nested hash #dig expects --
    # confirmed to raise TypeError, not just return nil) -- this must not be
    # saved as a complete-but-undercounted snapshot that silently drops BTC.
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [
        { "native_asset" => "XETH", "amount_allocated" => "unexpected-string-shape" },
        { "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "2.0" } } }
      ]
    )

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    earn_assets = account.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal 1, earn_assets.size, "expected the carried-forward snapshot, not a partial new one"
    assert_equal "BTC", earn_assets.first["symbol"]
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

  # There is no DOT28.S ticker: a bonded balance has to be priced as the asset
  # underneath it. Priced as the wallet variant it comes back "missing" and the
  # holding is dropped, so a staked position vanishes from the snapshot.
  test "prices a bonded balance as its underlying asset" do
    @provider.stubs(:get_asset_info).returns("DOT28.S" => { "altname" => "DOT28.S" })
    @provider.stubs(:get_extended_balance).returns(
      "DOT28.S" => { "balance" => "10.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_ticker).with("DOTUSD").returns("DOTUSD" => { "c" => [ "4.00" ] })

    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    account = @item.kraken_accounts.first
    dot = account.raw_payload["assets"].first
    assert_equal "exact", dot["price_status"]
    assert_in_delta 4.0, dot["price_usd"].to_d, 0.001
    assert_in_delta 40.0, account.current_balance, 0.01
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
