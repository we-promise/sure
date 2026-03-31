require "test_helper"

class BinanceAccount::TransactionsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @binance_item = BinanceItem.create!(
      family: @family,
      name: "Test Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
    @binance_account = @binance_item.binance_accounts.create!(
      name: "Binance Spot",
      account_id: "spot",
      currency: "USD",
      current_balance: 1000
    )
    @account = @family.accounts.create!(
      accountable: Crypto.create!(subtype: "exchange"),
      name: "Linked Binance",
      balance: 0,
      currency: "USD"
    )
    AccountProvider.create!(account: @account, provider: @binance_account)

    @security = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", offline: true)
    Security::Resolver.any_instance.stubs(:resolve).returns(@security)
  end

  test "processes deposits as positive contributions when valuation is unavailable" do
    @binance_account.update!(
      raw_transactions_payload: {
        "deposits" => [
          {
            "txId" => "deposit-1",
            "coin" => "USDC",
            "amount" => "250.00",
            "status" => 1,
            "insertTime" => Time.utc(2026, 1, 5, 12).to_i * 1000
          }
        ]
      }
    )

    assert_difference -> { @account.entries.count }, 1 do
      BinanceAccount::TransactionsProcessor.new(@binance_account).process
    end

    entry = @account.entries.find_by!(external_id: "binance_deposit_deposit-1", source: "binance")
    assert_equal BigDecimal("250.0"), entry.amount
    assert_equal "USDC", entry.currency
    assert_equal "Contribution", entry.transaction.investment_activity_label
  end

  test "processes withdrawals as negative withdrawals including fees when valuation is unavailable" do
    @binance_account.update!(
      raw_transactions_payload: {
        "withdrawals" => [
          {
            "txId" => "withdraw-1",
            "coin" => "ETH",
            "amount" => "1.5",
            "transactionFee" => "0.01",
            "status" => 6,
            "applyTime" => "2026-01-05 12:30:00"
          }
        ]
      }
    )

    assert_difference -> { @account.entries.count }, 1 do
      BinanceAccount::TransactionsProcessor.new(@binance_account).process
    end

    entry = @account.entries.find_by!(external_id: "binance_withdraw_withdraw-1", source: "binance")
    assert_equal BigDecimal("-1.51"), entry.amount
    assert_equal "ETH", entry.currency
    assert_equal "Withdrawal", entry.transaction.investment_activity_label
  end

  test "processes buy trades with quote-currency fallback and fee-adjusted cash outflow" do
    @binance_account.update!(
      raw_transactions_payload: {
        "trades" => [
          {
            "id" => 101,
            "symbol" => "BTCUSDT",
            "base_asset" => "BTC",
            "quote_asset" => "USDT",
            "price" => "50000",
            "qty" => "0.1",
            "quoteQty" => "5000",
            "commission" => "5",
            "commission_asset" => "USDT",
            "time" => Time.utc(2026, 1, 5).to_i * 1000,
            "isBuyer" => true
          }
        ]
      }
    )

    assert_difference -> { @account.entries.count }, 1 do
      BinanceAccount::TransactionsProcessor.new(@binance_account).process
    end

    entry = @account.entries.find_by!(external_id: "binance_trade_BTCUSDT_101", source: "binance")
    assert_equal BigDecimal("-5005"), entry.amount
    assert_equal "USDT", entry.currency
    assert_equal BigDecimal("0.1"), entry.trade.qty
    assert_equal BigDecimal("50000"), entry.trade.price
    assert_equal "Buy", entry.trade.investment_activity_label
  end

  test "processes sell trades as positive net proceeds in the valuation currency" do
    @binance_account.update!(
      raw_transactions_payload: {
        "trades" => [
          {
            "id" => 202,
            "symbol" => "BTCUSDT",
            "base_asset" => "BTC",
            "quote_asset" => "USDT",
            "price" => "50000",
            "qty" => "0.1",
            "quoteQty" => "5000",
            "commission" => "10",
            "commission_asset" => "USDT",
            "commission_valuation_amount" => "10",
            "valuation_currency" => "USD",
            "valuation_amount" => "5000",
            "valuation_price" => "50000",
            "time" => Time.utc(2026, 1, 6).to_i * 1000,
            "isBuyer" => false
          }
        ]
      }
    )

    assert_difference -> { @account.entries.count }, 1 do
      BinanceAccount::TransactionsProcessor.new(@binance_account).process
    end

    entry = @account.entries.find_by!(external_id: "binance_trade_BTCUSDT_202", source: "binance")
    assert_equal BigDecimal("4990"), entry.amount
    assert_equal "USD", entry.currency
    assert_equal BigDecimal("-0.1"), entry.trade.qty
    assert_equal BigDecimal("50000"), entry.trade.price
    assert_equal "Sell", entry.trade.investment_activity_label
  end
end
