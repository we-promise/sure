# frozen_string_literal: true

require "test_helper"

class BinanceAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "EUR")

    @item = BinanceItem.create!(
      family: @family, name: "Binance", api_key: "k", api_secret: "s"
    )
    @ba = @item.binance_accounts.create!(
      name: "Binance", account_type: "combined", currency: "USD", current_balance: 1000
    )
    @account = Account.create!(
      family: @family,
      name:   "Binance",
      balance: 0,
      currency: "EUR",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)

    BinanceAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @ba.stubs(:binance_item).returns(
      stub(binance_provider: nil, family: @family)
    )
  end

  test "converts USD balance to family currency when exact rate exists" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    @ba.reload
    assert_equal "EUR", @account.currency
    assert_in_delta 920.0, @account.balance, 0.01
    assert_equal false, @ba.extra.dig("binance", "stale_rate")
  end

  test "uses nearest rate and sets stale flag when exact rate missing" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current - 3, rate: 0.90)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    @ba.reload
    assert_equal "EUR", @account.currency
    assert_in_delta 900.0, @account.balance, 0.01
    assert_equal true, @ba.extra.dig("binance", "stale_rate")
  end

  test "falls back to USD amount and sets stale flag when no rate available" do
    ExchangeRate.expects(:find_or_fetch_rate).returns(nil)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    @ba.reload
    assert_in_delta 1000.0, @account.balance, 0.01
    assert_equal true, @ba.extra.dig("binance", "stale_rate")
  end

  test "clears stale flag on subsequent sync when exact rate found" do
    @ba.update!(extra: { "binance" => { "stale_rate" => true } })
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    @ba.reload
    assert_equal false, @ba.extra.dig("binance", "stale_rate")
  end

  test "does not convert when family uses USD" do
    @family.update!(currency: "USD")

    BinanceAccount::Processor.new(@ba).process

    @account.reload
    assert_equal "USD", @account.currency
    assert_in_delta 1000.0, @account.balance, 0.01
  end

  test "finishes P2P backfill when time advances during the final request" do
    travel_to Time.utc(2026, 11, 4, 12) do
      @family.update!(currency: "USD")
      @item.update!(sync_start_date: 31.days.ago)
      provider = mock
      @item.stubs(:binance_provider).returns(provider)
      @ba.stubs(:binance_item).returns(@item)
      start_time = @item.sync_start_date.to_i * 1000
      finish_time = Time.current.to_i * 1000
      first_end = start_time + 30.days.to_i * 1000

      provider.expects(:get_all_p2p_trades).with(start_timestamp: start_time, end_timestamp: first_end).returns([])
      provider.expects(:get_all_p2p_trades).with do |start_timestamp:, end_timestamp:|
        matches = start_timestamp == first_end + 1 && end_timestamp == finish_time
        travel 2.seconds if matches
        matches
      end.returns([])

      BinanceAccount::Processor.new(@ba).process

      assert_equal [], @ba.reload.raw_transactions_payload["p2p"]
    end
  end

  test "spot history without a start date begins within 24 hours and paginates by ID" do
    travel_to Time.utc(2026, 11, 5, 12) do
      @item.update!(sync_start_date: nil)
      @ba.stubs(:binance_item).returns(@item)
      provider = mock
      start_ms = 24.hours.ago.to_i * 1000
      now_ms = Time.current.to_i * 1000
      first_page = (1..1000).map { |id| { "id" => id, "time" => start_ms } }
      next_page = [ { "id" => 1001, "time" => start_ms } ]
      provider.expects(:get_spot_trades).with("BTCUSDT", limit: 1000, from_id: nil, start_time: start_ms, end_time: now_ms).returns(first_page)
      provider.expects(:get_spot_trades).with("BTCUSDT", limit: 1000, from_id: 1001, start_time: nil, end_time: nil).returns(next_page)
      provider.expects(:get_spot_trades).with("BTCUSDT", limit: 1000, from_id: 1002, start_time: nil, end_time: nil).returns([])
      processor = BinanceAccount::Processor.new(@ba)
      cursors = {}

      trades = processor.send(:fetch_new_trades, provider, "BTCUSDT", nil, :spot, cursors: cursors)
      assert_equal (1..1001).to_a, trades.map { |trade| trade["id"] }
      assert_equal 1001, cursors["BTCUSDT"]
      assert_empty processor.send(:fetch_new_trades, provider, "BTCUSDT", nil, :spot, cursors: cursors)
    end
  end

  test "initial spot history uses trade IDs and respects the configured start date" do
    @family.update!(currency: "USD")
    @item.update!(sync_start_date: Time.utc(2024, 1, 1))
    @ba.update!(raw_payload: { "assets" => [ { "symbol" => "BTC", "total" => "1" } ], "futures" => nil })
    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_all_p2p_trades).returns([])
    provider.stubs(:get_spot_trades).returns([])
    provider.expects(:get_futures_trades).never
    trades = [ 2023, 2024 ].map do |year|
      { "id" => year, "time" => Time.utc(year, 6, 1).to_i * 1000, "qty" => "0.1", "price" => "40000",
        "quoteQty" => "4000", "commission" => "0", "commissionAsset" => "USDT", "isBuyer" => true }
    end
    provider.expects(:get_spot_trades).with("BTCUSDT", limit: 1000, from_id: 0, start_time: nil, end_time: nil).returns(trades)

    BinanceAccount::Processor.new(@ba).process

    assert @account.entries.exists?(external_id: "binance_spot_BTCUSDT_2024")
    assert_not @account.entries.exists?(external_id: "binance_spot_BTCUSDT_2023")
  end

  test "spot history advances through discarded pages and resumes from the scanned cursor" do
    @family.update!(currency: "USD")
    @item.update!(sync_start_date: Time.utc(2024, 1, 1))
    @ba.update!(raw_payload: { "assets" => [ { "symbol" => "BTC", "total" => "1" } ], "futures" => nil })
    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_all_p2p_trades).returns([])
    provider.stubs(:get_spot_trades).returns([])
    old = (1..1000).map { |id| { "id" => id, "time" => Time.utc(2023, 1, 1).to_i * 1000 } }
    eligible = { "id" => 1001, "time" => Time.utc(2024, 6, 1).to_i * 1000, "qty" => "1", "price" => "10",
                 "quoteQty" => "10", "commission" => "0", "commissionAsset" => "USDT", "isBuyer" => true }
    provider.expects(:get_spot_trades).with("BTCUSDT", limit: 1000, from_id: 0, start_time: nil, end_time: nil).returns(old).once
    provider.expects(:get_spot_trades).with("BTCUSDT", limit: 1000, from_id: 1001, start_time: nil, end_time: nil).returns([ eligible ]).once
    provider.expects(:get_spot_trades).with("BTCUSDT", limit: 1000, from_id: 1002, start_time: nil, end_time: nil).returns([]).once
    provider.expects(:get_spot_trades).with("BTCEUR", limit: 1000, from_id: 0, start_time: nil, end_time: nil).returns(old.first(1)).once
    provider.expects(:get_spot_trades).with("BTCEUR", limit: 1000, from_id: 2, start_time: nil, end_time: nil).returns([]).once

    2.times { BinanceAccount::Processor.new(@ba).process }

    assert @account.entries.exists?(external_id: "binance_spot_BTCUSDT_1001")
    assert_equal 1, @ba.reload.raw_transactions_payload.dig("spot_cursors", "BTCEUR")
  end

  test "repairs a cached trade with a legacy quoted security" do
    @family.update!(currency: "USD")
    old_security = Security.create!(ticker: "BTCBRL", name: "BTC / BRL")
    entry = @account.entries.create!(date: Date.current, name: "Buy BTC", amount: 10, currency: "USD",
      external_id: "binance_spot_BTCUSDT_42", source: "binance",
      entryable: Trade.new(security: old_security, qty: 1, price: 10, currency: "USD", investment_activity_label: "Buy"))
    @ba.update!(raw_transactions_payload: { "spot" => { "BTCUSDT" => [ { "id" => 42 } ] } })
    provider = stub(get_all_p2p_trades: [], get_spot_trades: [], get_futures_trades: [])
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)

    assert_no_difference "Entry.count" do
      BinanceAccount::Processor.new(@ba).process
    end

    assert_equal "CRYPTO:BTC", entry.reload.entryable.security.ticker
  end

  test "processes futures trades correctly" do
    @family.update!(currency: "USD")
    @ba.update!(raw_payload: { "assets" => [ { "symbol" => "BTC", "total" => "1.0" } ] })

    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_spot_trades).returns([])
    provider.stubs(:get_spot_price).returns("50000.0")
    provider.stubs(:get_all_p2p_trades).returns([]) # Skip P2P

    # No cached trades -> initial sync walks time windows. First window returns
    # the trade, every later window/pair returns nothing.
    provider.stubs(:get_futures_trades).returns(
      [ { "id" => 1, "time" => 1610000000000, "qty" => "0.1", "price" => "40000.0", "quoteQty" => "4000.0", "commission" => "0.0", "commissionAsset" => "USDT", "buyer" => true } ],
      []
    )

    Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: "binance_public")

    assert_difference "Entry.count", 1 do
      BinanceAccount::Processor.new(@ba).process
    end

    assert @account.entries.exists?(external_id: "binance_futures_BTCUSDT_1")
  end

  test "initial futures sync walks multiple 7-day windows from sync_start_date" do
    @family.update!(currency: "USD")
    @item.update!(sync_start_date: 20.days.ago)
    @ba.update!(raw_payload: { "assets" => [ { "symbol" => "BTC", "total" => "1.0" } ] })

    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_spot_trades).returns([])
    provider.stubs(:get_spot_price).returns("50000.0")
    provider.stubs(:get_all_p2p_trades).returns([])

    trade = ->(id) {
      { "id" => id, "time" => 1610000000000, "qty" => "0.1", "price" => "40000.0", "quoteQty" => "4000.0", "commission" => "0.0", "commissionAsset" => "USDT", "buyer" => true }
    }

    # A 20-day span splits into three consecutive 7-day windows; each returns a
    # distinct trade, then all remaining windows/pairs return nothing.
    provider.stubs(:get_futures_trades).returns([ trade.call(1) ], [ trade.call(2) ], [ trade.call(3) ], [])

    Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: "binance_public")

    assert_difference "Entry.count", 3 do
      BinanceAccount::Processor.new(@ba).process
    end

    assert @account.entries.exists?(external_id: "binance_futures_BTCUSDT_1")
    assert @account.entries.exists?(external_id: "binance_futures_BTCUSDT_2")
    assert @account.entries.exists?(external_id: "binance_futures_BTCUSDT_3")
  end

  test "incremental sync paginates by fromId across full pages" do
    @family.update!(currency: "USD")
    @ba.update!(
      raw_payload: { "assets" => [ { "symbol" => "BTC", "total" => "1.0" } ] },
      raw_transactions_payload: {
        "futures" => { "BTCUSDT" => [ { "id" => 100, "time" => 1610000000000 } ] }
      }
    )

    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_spot_trades).returns([])
    provider.stubs(:get_spot_price).returns("50000.0")
    provider.stubs(:get_all_p2p_trades).returns([])

    full_page = (101..1100).map do |id|
      { "id" => id, "time" => 1610000000000, "qty" => "0.1", "price" => "40000.0", "quoteQty" => "4000.0", "commission" => "0.0", "commissionAsset" => "USDT", "buyer" => true }
    end
    last_page = [ { "id" => 1101, "time" => 1610000000000, "qty" => "0.1", "price" => "40000.0", "quoteQty" => "4000.0", "commission" => "0.0", "commissionAsset" => "USDT", "buyer" => true } ]

    # First BTCUSDT futures call returns a full 1000-row page (triggers a second
    # fromId request); the follow-up returns the final partial page. Other pairs
    # have no cached trades, so their window scans return nothing.
    provider.stubs(:get_futures_trades).returns(full_page, last_page, [])

    Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: "binance_public")

    assert_difference "Entry.count", 1001 do
      BinanceAccount::Processor.new(@ba).process
    end

    assert @account.entries.exists?(external_id: "binance_futures_BTCUSDT_101")
    assert @account.entries.exists?(external_id: "binance_futures_BTCUSDT_1101")
  end

  test "processes P2P BUY trades with double-entry logic and exact native fiat" do
    @family.update!(currency: "USD")
    @account.update!(currency: "USD")

    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)

    # Silence other importers
    provider.stubs(:get_spot_trades).returns([])
    provider.stubs(:get_futures_trades).returns([])

    # Mock the exact TZS/USDT payload with actual fiat transfer amounts
    provider.stubs(:get_all_p2p_trades).returns([
      {
        "orderNumber" => "22883918231657005056",
        "createTime" => 1777736533166,
        "tradeType" => "BUY",
        "asset" => "USDT",
        "fiat" => "TZS",
        "totalPrice" => "31500.00",
        "unitPrice" => "2746.29",
        "amount" => "11.47",          # Gross crypto
        "takerAmount" => "11.41",     # Net crypto
        "takerCommission" => "0.06"   # Crypto fee
      }
    ])

    Security.create!(ticker: "CRYPTO:USDT", name: "Tether", price_provider: "binance_public")

    # It MUST create 2 entries: 1 Deposit (Transaction) and 1 Purchase (Trade)
    assert_difference "Entry.count", 2 do
      BinanceAccount::Processor.new(@ba).process
    end

    # Verify the Deposit (Transaction) - Should be native fiat
    deposit = @account.entries.find_by(external_id: "binance_p2p_22883918231657005056_funding")
    assert_not_nil deposit
    assert_equal "Transaction", deposit.entryable_type
    assert_equal (-31500.00), deposit.amount.to_f # Negative = Fiat Cash INFLOW
    assert_equal "TZS", deposit.currency

    # Verify the Buy (Trade) - Should reflect the fiat cost basis
    trade = @account.entries.find_by(external_id: "binance_p2p_22883918231657005056")
    assert_not_nil trade
    assert_equal "Trade", trade.entryable_type
    assert_equal 31500.00, trade.amount.to_f    # Positive = Fiat Cash OUTFLOW
    assert_equal "TZS", trade.currency
    assert_equal "Buy", trade.entryable.investment_activity_label

    # Verify the specific crypto math and fiat fee conversion
    assert_equal 11.41, trade.entryable.qty.to_f

    # Fiat Fee = Crypto Fee (0.06) * Unit Price (2746.29) = 164.7774 (rounds to 164.78)
    assert_equal 164.78, trade.entryable.fee.to_f
  end

  test "skips processing if P2P external_id already exists" do
    @family.update!(currency: "USD")
    @account.update!(currency: "USD")

    # Pre-create the trade in the database
    @account.entries.create!(
      date: Date.current,
      name: "Existing P2P",
      amount: 10,
      currency: "USD",
      external_id: "binance_p2p_existing_123",
      entryable: Transaction.new
    )

    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_spot_trades).returns([])
    provider.stubs(:get_futures_trades).returns([])

    # Mock a payload with the SAME orderNumber
    provider.stubs(:get_all_p2p_trades).returns([
      { "orderNumber" => "existing_123", "tradeType" => "BUY", "asset" => "USDT", "amount" => "10.0" }
    ])

    Security.create!(ticker: "CRYPTO:USDT", name: "Tether", price_provider: "binance_public")

    # Assert that NO new entries are created
    assert_no_difference "Entry.count" do
      BinanceAccount::Processor.new(@ba).process
    end
  end

  # Binance opens at zero through the same shared path as Kraken, so it needs
  # the same repair: history older than the anchor leaves the account starting
  # after entries it is supposed to precede.
  test "moves the opening anchor before the first entry" do
    Account::OpeningBalanceManager.new(@account).set_opening_balance(balance: 0, date: 2.years.ago.to_date)
    @account.entries.create!(
      date: 3.years.ago.to_date,
      name: "Old trade",
      amount: 10,
      currency: "EUR",
      entryable: Transaction.new
    )

    BinanceAccount::Processor.new(@ba).process

    # A fresh instance: the manager memoises the anchor it last read.
    account = Account.find(@account.id)
    assert_equal 3.years.ago.to_date.prev_day, account.opening_anchor_date
    assert_equal 0, account.opening_anchor_balance
  end
end
