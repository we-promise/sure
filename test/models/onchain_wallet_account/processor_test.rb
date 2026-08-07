# frozen_string_literal: true

require "test_helper"

class OnchainWalletAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")
    @wallet_account = @item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080",
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      currency: "USD",
      quantity: 0.5,
      current_balance: 30_000,
      raw_transactions_payload: {
        "transactions" => [
          { "txid" => "buy_tx",  "onchain_amount" => "0.8",  "timeStamp" => Time.utc(2024, 1, 2).to_i },
          { "txid" => "sell_tx", "onchain_amount" => "-0.3", "timeStamp" => Time.utc(2024, 8, 10).to_i }
        ]
      }
    )
    @account = Account.create_from_onchain_wallet_account(@wallet_account)
    @wallet_account.ensure_account_provider!(@account)
  end

  test "creates Buy/Sell trades with cost basis when a historical price is available" do
    security = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin", exchange_operating_mic: "BNCX", offline: false)
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(security)
    security.stubs(:find_or_fetch_price).returns(OpenStruct.new(price: 50_000, currency: "USD"))

    OnchainWalletAccount::Processor.new(@wallet_account).process

    trades = @account.entries.where(entryable_type: "Trade").includes(:entryable).index_by { |e| e.entryable.qty.positive? ? :buy : :sell }
    assert_equal 2, @account.entries.where(entryable_type: "Trade").count

    assert_equal BigDecimal("0.8"), trades[:buy].entryable.qty
    assert_equal "Buy", trades[:buy].entryable.investment_activity_label
    assert_equal Date.new(2024, 1, 2), trades[:buy].date

    assert_equal BigDecimal("-0.3"), trades[:sell].entryable.qty
    assert_equal "Sell", trades[:sell].entryable.investment_activity_label
  end

  test "falls back to display-only transaction stubs when no price is available" do
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    OnchainWalletAccount::Processor.new(@wallet_account).process

    assert_equal 0, @account.entries.where(entryable_type: "Trade").count
    stubs = @account.entries.where(entryable_type: "Transaction", source: "onchain_wallet")
    assert_equal 2, stubs.count
    assert stubs.all?(&:excluded?)
    assert stubs.all? { |e| e.amount.zero? }
  end

  test "records current anchor valuation for balance materialization" do
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)
    @wallet_account.update!(current_balance: 35_000)

    OnchainWalletAccount::Processor.new(@wallet_account).process

    current_anchor = @account.valuations.current_anchor.includes(:entry).first
    assert_not_nil current_anchor
    assert_equal Date.current, current_anchor.entry.date
    assert_equal BigDecimal("35000"), current_anchor.entry.amount
    assert_equal BigDecimal("35000"), @account.reload.balance
    assert_equal 0, @account.cash_balance
  end

  test "rolls back account balance fields when current anchor update fails" do
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)
    @account.update!(cash_balance: 123, currency: "EUR")
    Account::CurrentBalanceManager.any_instance
      .stubs(:set_current_balance)
      .returns(Account::CurrentBalanceManager::Result.new(success?: false, changes_made?: false, error: "anchor failed"))

    assert_raises(RuntimeError, "anchor failed") do
      OnchainWalletAccount::Processor.new(@wallet_account).process
    end

    @account.reload
    assert_equal BigDecimal("123"), @account.cash_balance
    assert_equal "EUR", @account.currency
  end
end
