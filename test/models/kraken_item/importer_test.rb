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
    @provider.stubs(:get_earn_strategies).returns({ "items" => [] })
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

  test "skips Earn allocations already in BalanceEx and keeps hybrid Earn" do
    @provider.stubs(:get_asset_info).returns(asset_metadata.merge("ETH.B" => { "altname" => "ETH.B" }))
    @provider.stubs(:get_extended_balance).returns(
      "ETH.B" => { "balance" => "8.4245", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" },
      "XETH" => { "balance" => "0.0005", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [
        { "strategy_id" => "bonded", "native_asset" => "ETH", "amount_allocated" => { "total" => { "native" => "8.4245" } } },
        { "strategy_id" => "flex", "native_asset" => "ETH", "amount_allocated" => { "total" => { "native" => "0.0005" } } },
        { "strategy_id" => "vault", "native_asset" => "BTC", "amount_allocated" => { "total" => { "native" => "0.08" } } }
      ]
    )
    @provider.stubs(:get_earn_strategies).returns("items" => [ { "id" => "bonded" }, { "id" => "flex" } ])
    @provider.stubs(:get_ticker).with("ETHUSD").returns("XETHZUSD" => { "c" => [ "2000.00" ] })
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })

    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    earn = @item.kraken_accounts.first.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal [ [ "BTC", "0.08" ] ], earn.map { |asset| [ asset["symbol"], asset["balance"] ] }
    assert_in_delta 20_850, @item.kraken_accounts.first.current_balance, 0.01
  end

  test "carries forward last known Earn assets when Earn/Strategies fails" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [ { "strategy_id" => "vault", "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "2.0" } } } ]
    )
    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    @provider.stubs(:get_earn_strategies).raises(Provider::Kraken::ApiError, "EGeneral:Internal error")
    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    assert result[:success]
    earn_btc = @item.kraken_accounts.first.raw_payload["assets"].find { |asset| asset["source"] == "earn" }
    assert_equal "2.0", earn_btc["balance"]
  end

  test "carries forward last known Earn assets when Earn/Strategies is incomplete" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [ { "strategy_id" => "vault", "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "2.0" } } } ]
    )
    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    [
      { "items" => [ { "name" => "no id" } ] },
      { "items" => [ { "id" => "bonded" } ], "next_cursor" => "same" }
    ].each do |response|
      @provider.stubs(:get_earn_strategies).returns(response)
      assert KrakenItem::Importer.new(@item, kraken_provider: @provider).import[:success]

      earn_btc = @item.kraken_accounts.first.raw_payload["assets"].find { |asset| asset["source"] == "earn" }
      assert_equal "2.0", earn_btc["balance"]
    end
  end

  test "merges Earn allocated balances alongside spot assets" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    # Includes a spot XXBT holding of the *same* asset Earn reports, so this
    # actually exercises what the importer's own comment promises: Earn
    # assets are tagged source: "earn" so they land as a separate holding
    # rather than colliding with a spot balance of the same asset.
    @provider.stubs(:get_extended_balance).returns(
      "XXBT" => { "balance" => "1.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" },
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
    spot_btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" && asset["source"] == "spot" }
    earn_btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" && asset["source"] == "earn" }
    assert_not_nil spot_btc, "the spot BTC holding must survive alongside the Earn one, not be overwritten by it"
    assert_equal "1.0", spot_btc["balance"]
    assert_not_nil earn_btc
    assert_equal "2.0", earn_btc["balance"]
    assert_equal "0", earn_btc["available"]
    assert_in_delta 100_000, earn_btc["amount_usd"].to_f, 0.01
    # 1.0 BTC spot + 2.0 BTC Earn, both @ $50,000, plus $50 cash.
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

  test "degrades gracefully when Earn Allocations times out at the transport level" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    # HTTParty/Net::HTTP raise this before a response ever reaches
    # Provider::Kraken#handle_response, so it's never classified into a
    # Provider::Kraken::Error -- it has to be rescued explicitly here too,
    # same reasoning as RateLimitError above, or a dropped connection on
    # this one call aborts the whole sync.
    @provider.stubs(:get_earn_allocations).raises(Timeout::Error, "execution expired")

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    assert_in_delta 50.0, account.current_balance, 0.01
  end

  test "carries forward last known Earn assets when the result is not an object" do
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

    # A scalar result has no #to_h at all (NoMethodError); calling #to_h on
    # it must never be reached before this is checked.
    @provider.stubs(:get_earn_allocations).returns("unexpected scalar result")

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    earn_assets = @item.kraken_accounts.first.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal 1, earn_assets.size, "expected the carried-forward snapshot, not a crash"
    assert_equal "BTC", earn_assets.first["symbol"]
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

  test "reprices a carried-forward Earn asset with a current price instead of the stale one" do
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

    # Earn fails on this sync and must carry the 2.0 BTC balance forward, but
    # BTC's price moved since the last successful Earn sync -- every spot
    # asset gets a current price every sync, so the carried Earn asset must
    # not be the one stale figure left behind.
    @provider.stubs(:get_earn_allocations).raises(Provider::Kraken::ApiError, "EGeneral:Internal error")
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "60000.00" ] })

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    earn_btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" && asset["source"] == "earn" }
    assert_equal "2.0", earn_btc["balance"], "the carried balance itself must be unchanged"
    assert_in_delta 60000.0, earn_btc["price_usd"].to_f, 0.01
    assert_in_delta 120000.0, earn_btc["amount_usd"].to_f, 0.01
    assert_in_delta 120050.0, account.current_balance, 0.01
  end

  test "leaves a carried Earn asset unchanged when no current price is available" do
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

    # Earn fails again, and this time no ticker price is available either
    # (the blanket get_ticker stub from setup returns nil for every pair
    # candidate) -- the carried asset must keep its last known price rather
    # than guessing or zeroing it out.
    @provider.stubs(:get_earn_allocations).raises(Provider::Kraken::ApiError, "EGeneral:Internal error")

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    earn_btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" && asset["source"] == "earn" }
    assert_in_delta 50000.0, earn_btc["price_usd"].to_f, 0.01
    assert_in_delta 100000.0, earn_btc["amount_usd"].to_f, 0.01
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

  test "degrades gracefully when Earn Allocations hits a nonce error, not just permission/API/rate-limit" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    # AuthenticationError/NonceError/OTPRequiredError are siblings of
    # ApiError/PermissionError/RateLimitError under Provider::Kraken::Error,
    # not subclasses of any of those three -- rescuing Provider::Kraken::Error
    # itself is what actually covers all of them in one place.
    @provider.stubs(:get_earn_allocations).raises(Provider::Kraken::NonceError, "EAPI:Invalid nonce")

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    assert_in_delta 50.0, account.current_balance, 0.01
  end

  test "deduplicates Earn allocations repeated across pages by strategy_id" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    btc_allocation = { "strategy_id" => "ESDQCOL-WTZEU-NU55QF", "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "2.0" } } }
    @provider.expects(:get_earn_allocations).with(cursor: nil).returns(
      "items" => [ btc_allocation ], "next_cursor" => "page2"
    )
    @provider.expects(:get_earn_allocations).with(cursor: "page2").returns(
      "items" => [ btc_allocation ] # same strategy_id repeated on a shifted cursor window
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    account = @item.kraken_accounts.first
    earn_assets = account.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal 1, earn_assets.size, "a repeated allocation must not be double-counted into two holdings"
    assert_in_delta 100_000, earn_assets.first["amount_usd"].to_f, 0.01
  end

  test "logs a carry-forward via DebugLogEntry, not only Rails.logger" do
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

    @provider.stubs(:get_earn_allocations).raises(Provider::Kraken::ApiError, "EGeneral:Internal error")

    assert_difference -> { DebugLogEntry.count }, 2 do # record_earn_unavailable + the carry-forward itself
      KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    end

    carry_forward_entry = DebugLogEntry.where("message LIKE ?", "Carrying%").last
    assert_not_nil carry_forward_entry, "the carry-forward itself must be visible in /settings/debug, not only Rails.logger"
    assert_equal "provider_sync_error", carry_forward_entry.category
  end

  test "treats a signed or exponent-notation Earn balance as numeric, not garbage" do
    @provider.stubs(:get_asset_info).returns(asset_metadata)
    @provider.stubs(:get_extended_balance).returns(
      "ZUSD" => { "balance" => "50.0", "credit" => "0", "credit_used" => "0", "hold_trade" => "0" }
    )
    # A leading "+" is valid input to String#to_d (so is exponent notation,
    # e.g. "1e-08"); the stricter plain-decimal-only regex this replaced
    # would have rejected this as "non-numeric" and routed it into the
    # carry-forward path despite being a real balance.
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [ { "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "+2.0" } } } ]
    )
    @provider.stubs(:get_ticker).with("XBTUSD").returns("XXBTZUSD" => { "c" => [ "50000.00" ] })

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    earn_btc = @item.kraken_accounts.first.raw_payload["assets"].find { |asset| asset["source"] == "earn" }
    assert_not_nil earn_btc
    assert_in_delta 100_000, earn_btc["amount_usd"].to_f, 0.01
  end

  test "prices a suffixed Earn allocation as its underlying asset" do
    @provider.stubs(:get_asset_info).returns("DOT28.S" => { "altname" => "DOT28.S" })
    @provider.stubs(:get_extended_balance).returns({})
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [ { "native_asset" => "DOT28.S", "amount_allocated" => { "total" => { "native" => "10.0" } } } ]
    )
    @provider.stubs(:get_ticker).with("DOTUSD").returns("DOTUSD" => { "c" => [ "4.00" ] })

    KrakenItem::Importer.new(@item, kraken_provider: @provider).import

    earn_dot = @item.kraken_accounts.first.raw_payload["assets"].find { |asset| asset["source"] == "earn" }
    assert_not_nil earn_dot
    assert_equal "exact", earn_dot["price_status"]
    assert_in_delta 4.0, earn_dot["price_usd"].to_d, 0.001
    assert_in_delta 40.0, earn_dot["amount_usd"].to_d, 0.01
  end

  test "carries forward last known Earn assets when an item is missing native_asset" do
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

    # A missing native_asset used to be dropped via `next` -- normal control
    # flow, not an exception -- so it never reached the carry-forward rescue
    # and silently saved a spot-only snapshot instead.
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [ { "amount_allocated" => { "total" => { "native" => "2.0" } } } ]
    )

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    earn_assets = @item.kraken_accounts.first.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal 1, earn_assets.size, "expected the carried-forward snapshot, not a spot-only one"
    assert_equal "BTC", earn_assets.first["symbol"]
  end

  test "carries forward last known Earn assets when amount_allocated.total.native is non-numeric" do
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

    # "N/A" is not blank, so it used to reach #to_d, which silently coerces
    # non-numeric strings to 0 -- read as a genuine zero balance and
    # filtered out via `next`, the same silent-drop bug as a missing field.
    @provider.stubs(:get_earn_allocations).returns(
      "items" => [ { "native_asset" => "XXBT", "amount_allocated" => { "total" => { "native" => "N/A" } } } ]
    )

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    earn_assets = @item.kraken_accounts.first.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal 1, earn_assets.size, "expected the carried-forward snapshot, not a spot-only one"
    assert_equal "BTC", earn_assets.first["symbol"]
  end

  test "carries forward last known Earn assets when the response is missing items" do
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

    # A response with no "items" key used to be read via `|| []` as "zero
    # Earn assets this sync" -- a clean, successful-looking empty snapshot
    # that saved over the previously-carried Earn principal instead of
    # raising into the carry-forward path.
    @provider.stubs(:get_earn_allocations).returns({})

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    earn_assets = @item.kraken_accounts.first.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal 1, earn_assets.size, "expected the carried-forward snapshot, not an empty one"
    assert_equal "BTC", earn_assets.first["symbol"]
  end

  test "carries forward last known Earn assets when items is not an array" do
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

    # "items" as a Hash instead of an Array used to raise an uncaught
    # TypeError from Array#concat, crashing the whole sync -- including the
    # spot balance that had already succeeded -- instead of degrading
    # gracefully like every other Earn-specific failure.
    @provider.stubs(:get_earn_allocations).returns("items" => { "unexpected" => "shape" })

    result = KrakenItem::Importer.new(@item, kraken_provider: @provider).import
    assert result[:success]

    earn_assets = @item.kraken_accounts.first.raw_payload["assets"].select { |asset| asset["source"] == "earn" }
    assert_equal 1, earn_assets.size, "expected the carried-forward snapshot, not a crash"
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
