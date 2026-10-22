require "test_helper"

class SaxoItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = families(:dylan_family).saxo_items.create!
    @raw = { "AccountId" => "123", "AccountKey" => "account-key", "ClientKey" => "client-key", "Currency" => "EUR" }
    @provider_account = @item.saxo_accounts.create!(account_id: "123", name: "PEA", currency: "EUR", raw_payload: @raw)
    @account = @provider_account.link!
    @provider = mock("Saxo provider")
    @item.stubs(:saxo_provider).returns(@provider)
    @provider.stubs(:accounts).returns([ @raw ])
    @provider.stubs(:balances).returns("Currency" => "EUR", "CalculationReliability" => "Ok", "TotalValue" => "1100", "CashBalance" => "100")
    @provider.stubs(:positions).returns([])
    @sync = OpenStruct.new(window_start_date: nil, window_end_date: nil)
    Account.any_instance.stubs(:sync_later)
    @item.family.stubs(:auto_match_transfers!)
  end

  test "initial history starts in 2010 and later syncs revisit sixty days" do
    @provider.expects(:history).with(@raw, since: Date.new(2010, 1, 1), until_date: Date.current).returns([])
    SaxoItem::Importer.new(@item).import(@sync)
    @provider.expects(:history).with(@raw, since: Date.current - 60, until_date: Date.current).returns([])
    SaxoItem::Importer.new(@item).import(@sync)
    assert_equal BigDecimal("1100"), @account.reload.balance
    assert_equal BigDecimal("100"), @account.cash_balance
  end

  test "conditional balance reliability permits validated positions" do
    @provider.stubs(:balances).returns("Currency" => "EUR", "CalculationReliability" => "OkWithConditions", "TotalValue" => "1100", "CashBalance" => "100")
    @provider.stubs(:history).returns([])
    SaxoItem::Importer.new(@item).import(@sync)
    assert_equal BigDecimal("1100"), @account.reload.balance
  end

  test "resuming after a long interruption imports the gap with a sixty day overlap" do
    last_synced_on = Date.current - 90
    @provider_account.update!(history_synced_on: last_synced_on)
    @provider.expects(:history).with(@raw, since: last_synced_on - 60, until_date: Date.current).returns([])

    SaxoItem::Importer.new(@item).import(@sync)

    assert_equal Date.current, @provider_account.reload.history_synced_on
  end

  test "the overlap never starts before the configured history start" do
    @item.update!(sync_start_date: Date.current - 100)
    @provider_account.update!(history_synced_on: Date.current - 90)
    @provider.expects(:history).with(@raw, since: @item.sync_start_date, until_date: Date.current).returns([])

    SaxoItem::Importer.new(@item).import(@sync)
  end

  test "full reconciliation overrides the usual lookback" do
    @provider_account.update!(history_synced_on: Date.current)
    @sync.window_start_date = Date.new(2010, 1, 1)
    @provider.expects(:history).with(@raw, since: Date.new(2010, 1, 1), until_date: Date.current).returns([])
    SaxoItem::Importer.new(@item).import(@sync)
  end

  test "linking to a different account imports the complete history again" do
    @provider_account.update!(history_synced_on: Date.yesterday)
    @provider_account.account_provider.destroy!
    @provider_account.reload.link!
    @provider.expects(:history).with(@raw, since: @item.sync_start_date, until_date: Date.current).returns([])

    SaxoItem::Importer.new(@item).import(@sync)
  end

  test "a changed Saxo currency does not overwrite the linked account balance" do
    @account.update!(balance: 150, cash_balance: 50)
    @provider_account.update!(history_synced_on: Date.yesterday)
    @provider.stubs(:accounts).returns([ @raw.merge("Currency" => "USD") ])
    @provider.expects(:balances).never

    error = assert_raises(Provider::Saxo::Error) { SaxoItem::Importer.new(@item).import(@sync) }
    assert_equal "currency_mismatch", error.diagnostic[:reason]
    assert_equal BigDecimal("150"), @account.reload.balance
    assert_equal BigDecimal("50"), @account.cash_balance
    assert_equal Date.yesterday, @provider_account.reload.history_synced_on
  end

  test "an unreliable position snapshot preserves holdings balances and the history cursor" do
    holding = @account.holdings.create!(security: securities(:aapl), account_provider: @provider_account.account_provider,
      date: Date.yesterday, qty: 2, amount: 100, price: 50, currency: "EUR")
    @account.update!(balance: 150, cash_balance: 50)
    @provider_account.update!(current_balance: 150, cash_balance: 50, history_synced_on: Date.yesterday)
    @provider.stubs(:history).returns([])
    @provider.stubs(:positions).returns([
      { "PositionBase" => { "AccountId" => "123", "AssetType" => "Stock", "Uic" => 101, "Amount" => "2" },
        "PositionView" => { "CalculationReliability" => "PricePending", "CurrentPrice" => "0", "MarketValueInBaseCurrency" => "0" },
        "DisplayAndFormat" => { "Symbol" => "EXAMPLE", "Currency" => "EUR" } }
    ])
    Account.any_instance.expects(:sync_later).never

    assert_no_difference [ "Entry.count", "Holding.count" ] do
      error = assert_raises(Provider::Saxo::Error) { SaxoItem::Importer.new(@item).import(@sync) }
      assert_equal "Saxo position valuation is unreliable", error.message
      assert_equal "PricePending", error.diagnostic[:calculation_reliability]
      assert_equal @provider_account.account_provider.id, error.diagnostic[:account_provider_id]
    end
    assert_equal BigDecimal("100"), holding.reload.amount
    assert_equal BigDecimal("2"), holding.qty
    assert_equal BigDecimal("150"), @account.reload.balance
    assert_equal BigDecimal("50"), @account.cash_balance
    assert_equal BigDecimal("150"), @provider_account.reload.current_balance
    assert_equal BigDecimal("50"), @provider_account.cash_balance
    assert_equal Date.yesterday, @provider_account.history_synced_on
  end

  test "an invalid second account leaves the first account financial data unchanged" do
    other_raw = @raw.merge("AccountId" => "456", "AccountKey" => "other-key")
    other = @item.saxo_accounts.create!(account_id: "456", name: "CTO", currency: "EUR", raw_payload: other_raw)
    other.link!
    @provider.stubs(:accounts).returns([ @raw, other_raw ])
    @provider.stubs(:balances).with(other_raw).returns("Currency" => "USD", "CalculationReliability" => "Ok")
    @provider.stubs(:history).returns([])
    assert_no_difference "Entry.count" do
      assert_raises(Provider::Saxo::Error) { SaxoItem::Importer.new(@item).import(@sync) }
    end
    assert_equal BigDecimal("0"), @account.reload.balance
    assert_nil @provider_account.reload.history_synced_on
  end

  test "history validation failures identify the linked provider account" do
    row = { "AccountId" => "123", "Currency" => "EUR", "Date" => "2026-10-20", "TransactionType" => "Trade",
      "Event" => "Buy", "Bookings" => [ { "BookingId" => "one", "BookedAmount" => "-100", "AmountType" => "Unknown" } ],
      "Trades" => [ { "TradeId" => "trade", "TradedQuantity" => "2", "Price" => "50",
        "Instrument" => { "Uic" => 101, "AssetType" => "Stock", "Symbol" => "EXAMPLE", "Currency" => "EUR" } } ] }
    @provider.stubs(:history).returns([ row ])

    error = assert_raises(Provider::Saxo::Error) { SaxoItem::Importer.new(@item).import(@sync) }
    assert_equal @provider_account.account_provider.id, error.diagnostic[:account_provider_id]
    assert_equal "unsupported_trade", error.diagnostic[:reason]
    assert_nil @provider_account.reload.history_synced_on
  end
end
