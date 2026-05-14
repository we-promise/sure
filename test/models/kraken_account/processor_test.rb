# frozen_string_literal: true

require "test_helper"

class KrakenAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = KrakenItem.create!(family: @family, name: "Kraken", api_key: "k", api_secret: "s")
    @kraken_account = @item.kraken_accounts.create!(
      name: "Kraken",
      account_id: "combined",
      account_type: "combined",
      currency: "USD",
      current_balance: 1000,
      raw_payload: {
        "asset_metadata" => {
          "XXBT" => { "altname" => "XBT" },
          "ZUSD" => { "altname" => "USD" }
        },
        "pair_metadata" => {
          "XXBTZUSD" => { "altname" => "XBTUSD", "base" => "XXBT", "quote" => "ZUSD" }
        }
      },
      raw_transactions_payload: {
        "trades" => {
          "buy_tx" => trade_payload("buy", "0.001", "50.00", "0.10"),
          "sell_tx" => trade_payload("sell", "0.002", "120.00", "0.20")
        }
      }
    )
    @account = Account.create!(
      family: @family,
      name: "Kraken",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @kraken_account)
    @security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XKRA", offline: true)
    KrakenAccount::SecurityResolver.stubs(:resolve).returns(@security)
    KrakenAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
  end

  test "imports buy and sell spot fills as trade entries" do
    assert_difference -> { @account.entries.where(source: "kraken").count }, 2 do
      KrakenAccount::Processor.new(@kraken_account).process
    end

    buy = @account.entries.find_by!(external_id: "kraken_trade_buy_tx", source: "kraken")
    assert_equal(-50.to_d, buy.amount)
    assert_equal "USD", buy.currency
    assert_equal 0.001.to_d, buy.trade.qty
    assert_equal 50_000.to_d, buy.trade.price
    assert_equal 0.10.to_d, buy.trade.fee
    assert_equal "Buy", buy.trade.investment_activity_label

    sell = @account.entries.find_by!(external_id: "kraken_trade_sell_tx", source: "kraken")
    assert_equal 120.to_d, sell.amount
    assert_equal(-0.002.to_d, sell.trade.qty)
    assert_equal 0.20.to_d, sell.trade.fee
    assert_equal "Sell", sell.trade.investment_activity_label
  end

  test "trade import is idempotent by txid" do
    assert_difference -> { @account.entries.where(source: "kraken").count }, 2 do
      KrakenAccount::Processor.new(@kraken_account).process
    end

    assert_no_difference -> { @account.entries.where(source: "kraken").count } do
      KrakenAccount::Processor.new(@kraken_account).process
    end
  end

  test "updates linked crypto account balance without cash balance" do
    KrakenAccount::Processor.new(@kraken_account).process

    @account.reload
    assert_equal 1000.to_d, @account.balance
    assert_equal 0.to_d, @account.cash_balance
    assert_equal "USD", @account.currency
  end

  private

    def trade_payload(type, volume, cost, fee)
      price = volume.to_d.zero? ? 0.to_d : cost.to_d / volume.to_d

      {
        "ordertxid" => "order_#{type}",
        "pair" => "XBTUSD",
        "time" => Time.current.to_f,
        "type" => type,
        "price" => price.to_s("F"),
        "cost" => cost,
        "fee" => fee,
        "vol" => volume
      }
    end
end
