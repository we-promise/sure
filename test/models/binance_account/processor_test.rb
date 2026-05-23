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

  test "processes futures trades correctly" do
    @family.update!(currency: "USD")
    @ba.update!(raw_payload: { "assets" => [ { "symbol" => "BTC", "total" => "1.0" } ] })

    provider = mock
    @item.stubs(:binance_provider).returns(provider)
    @ba.stubs(:binance_item).returns(@item)
    provider.stubs(:get_spot_trades).returns([])
    provider.stubs(:get_spot_price).returns("50000.0")
    provider.stubs(:get_all_p2p_trades).returns([]) # Skip P2P

    # Mock futures trades
    provider.stubs(:get_futures_trades).returns([])
    provider.stubs(:get_futures_trades).with("BTCUSDT", limit: 1000, from_id: nil, startTime: nil).returns([
      { "id" => 1, "time" => 1610000000000, "qty" => "0.1", "price" => "40000.0", "quoteQty" => "4000.0", "commission" => "0.0", "commissionAsset" => "USDT", "buyer" => true }
    ])

    Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", price_provider: "binance_public")

    assert_difference "Entry.count", 1 do
      BinanceAccount::Processor.new(@ba).process
    end

    assert @account.entries.exists?(external_id: "binance_futures_BTCUSDT_1")
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
end
