# frozen_string_literal: true

require "test_helper"

class CoinspotAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "AUD")
    @item = CoinspotItem.create!(family: @family, name: "CoinSpot", api_key: "k", api_secret: "s")
    @coinspot_account = @item.coinspot_accounts.create!(
      name: "CoinSpot",
      account_id: "combined",
      account_type: "combined",
      currency: "AUD",
      current_balance: 1000,
      raw_payload: {
        "assets" => [
          { "symbol" => "BTC", "balance" => "0.01", "amount_aud" => "1000.00", "price_aud" => "100000.00" }
        ]
      },
      raw_transactions_payload: {
        "orders" => {
          "buyorders" => [
            order_payload("buy-1", "btc", "0.001", "100.00", "100000.00", "1.00")
          ],
          "sellorders" => [
            order_payload("sell-1", "btc", "0.002", "220.00", "110000.00", "2.00")
          ]
        },
        "send_receive" => {
          "sendtransactions" => [
            { "txid" => "send-1", "coin" => "btc", "amount" => "0.001", "aud" => "100.00", "sendfee" => "0.00001", "timestamp" => "2026-01-04T10:00:00Z" }
          ],
          "receivetransactions" => [
            { "txid" => "receive-1", "coin" => "btc", "amount" => "0.002", "aud" => "200.00", "timestamp" => "2026-01-05T10:00:00Z" }
          ]
        },
        "deposits" => {
          "deposits" => [
            { "reference" => "deposit-1", "amount" => "300.00", "created" => "2026-01-06T10:00:00Z" }
          ]
        },
        "withdrawals" => {
          "withdrawals" => [
            { "reference" => "withdrawal-1", "amount" => "150.00", "created" => "2026-01-07T10:00:00Z" }
          ]
        }
      }
    )
    @account = Account.create!(
      family: @family,
      name: "CoinSpot",
      balance: 0,
      currency: "AUD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @coinspot_account)
    @security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XCSO", offline: true)
    CoinspotAccount::SecurityResolver.stubs(:resolve).returns(@security)
    CoinspotAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
  end

  test "imports orders, transfers, fiat movements, and native send fees" do
    assert_difference -> { @account.entries.where(source: "coinspot").count }, 9 do
      CoinspotAccount::Processor.new(@coinspot_account).process
    end

    buy = @account.entries.find_by!(external_id: "coinspot_order_buy_BTC_2026-01-02_buy-1", source: "coinspot")
    assert_equal(-100.to_d, buy.amount)
    assert_equal 0.001.to_d, buy.trade.qty
    assert_equal 100_000.to_d, buy.trade.price
    assert_equal "Buy", buy.trade.investment_activity_label

    sell = @account.entries.find_by!(external_id: "coinspot_order_sell_BTC_2026-01-03_sell-1", source: "coinspot")
    assert_equal 220.to_d, sell.amount
    assert_equal(-0.002.to_d, sell.trade.qty)
    assert_equal "Sell", sell.trade.investment_activity_label

    fee = @account.entries.find_by!(external_id: "coinspot_fee_#{Digest::SHA256.hexdigest(@coinspot_account.raw_transactions_payload.dig("send_receive", "sendtransactions").first.to_json)[0, 24]}", source: "coinspot")
    assert_equal 1.to_d, fee.amount
    assert_equal "Fee", fee.transaction.investment_activity_label

    deposit = @account.entries.find_by!(external_id: "coinspot_deposit_aud_2026-01-06_deposit-1", source: "coinspot")
    assert_equal(-300.to_d, deposit.amount)
    assert_equal "Contribution", deposit.transaction.investment_activity_label

    withdrawal = @account.entries.find_by!(external_id: "coinspot_withdrawal_aud_2026-01-07_withdrawal-1", source: "coinspot")
    assert_equal 150.to_d, withdrawal.amount
    assert_equal "Withdrawal", withdrawal.transaction.investment_activity_label
  end

  test "processing is idempotent by external id and source" do
    assert_difference -> { @account.entries.where(source: "coinspot").count }, 9 do
      CoinspotAccount::Processor.new(@coinspot_account).process
    end

    assert_no_difference -> { @account.entries.where(source: "coinspot").count } do
      CoinspotAccount::Processor.new(@coinspot_account).process
    end
  end

  test "updates linked crypto account balance without cash balance" do
    CoinspotAccount::Processor.new(@coinspot_account).process

    @account.reload
    assert_equal 1000.to_d, @account.balance
    assert_equal 0.to_d, @account.cash_balance
    assert_equal "AUD", @account.currency
  end

  test "derives market order price from aud total instead of quote asset rate" do
    @coinspot_account.update!(
      raw_transactions_payload: {
        "orders" => {
          "orders" => [
            {
              "id" => "eth-btc-1",
              "market" => "ETH/BTC",
              "amount" => "2.0",
              "audtotal" => "6000.00",
              "rate" => "0.05",
              "created" => "2026-01-08T10:00:00Z",
              "type" => "buy"
            }
          ]
        }
      }
    )
    eth = Security.create!(ticker: "CRYPTO:ETH", name: "ETH", exchange_operating_mic: "XCSO", offline: true)
    CoinspotAccount::SecurityResolver.stubs(:resolve).with("ETH").returns(eth)

    CoinspotAccount::Processor.new(@coinspot_account).process

    trade = @account.entries.find_by!(external_id: "coinspot_order_buy_ETH_2026-01-08_eth-btc-1", source: "coinspot").trade
    assert_equal 2.to_d, trade.qty
    assert_equal 3000.to_d, trade.price
  end

  private

    def order_payload(id, coin, amount, audtotal, rate, fee)
      {
        "id" => id,
        "coin" => coin,
        "amount" => amount,
        "audtotal" => audtotal,
        "rate" => rate,
        "audfeeExGst" => fee,
        "audGst" => "0.00",
        "created" => id.start_with?("buy") ? "2026-01-02T10:00:00Z" : "2026-01-03T10:00:00Z"
      }
    end
end
