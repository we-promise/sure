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

  # The account is created, and anchored two years back, before any history
  # is imported. A ledger older than that then starts before its own opening
  # balance, and the reverse calculator pins the balance to the anchor and
  # derives every earlier day from it with the flows running the wrong way.
  test "moves the opening anchor before the first imported entry" do
    old_trade = trade_payload("buy", "0.001", "50.00", "0.10").merge("time" => 3.years.ago.to_f)
    kraken_account = @item.kraken_accounts.create!(
      name: "Kraken (old)", account_id: "old", account_type: "combined", currency: "USD", current_balance: 50,
      raw_payload: @kraken_account.raw_payload,
      raw_transactions_payload: { "trades" => { "old_tx" => old_trade } }
    )
    account = Account.create_from_kraken_account(kraken_account)
    AccountProvider.create!(account: account, provider: kraken_account)
    assert_equal 2.years.ago.to_date, account.opening_anchor_date

    KrakenAccount::Processor.new(kraken_account).process

    # A fresh instance: the manager memoises the anchor it last read.
    account = Account.find(account.id)
    assert account.entries.exists?(external_id: "kraken_trade_old_tx"), "the old trade must have been imported"
    assert_equal 3.years.ago.to_date.prev_day, account.opening_anchor_date
    assert_equal 0, account.opening_anchor_balance
  end

  # A reconciliation older than the first trade is still an entry, so the date
  # the anchor moves to has to clear it too -- the manager validates against
  # every entry, not just the ones that are not valuations.
  test "moves the opening anchor before an older valuation too" do
    old_trade = trade_payload("buy", "0.001", "50.00", "0.10").merge("time" => 3.years.ago.to_f)
    kraken_account = @item.kraken_accounts.create!(
      name: "Kraken (valuation)", account_id: "val", account_type: "combined", currency: "USD", current_balance: 50,
      raw_payload: @kraken_account.raw_payload,
      raw_transactions_payload: { "trades" => { "old_tx" => old_trade } }
    )
    account = Account.create_from_kraken_account(kraken_account)
    AccountProvider.create!(account: account, provider: kraken_account)
    account.entries.create!(
      date: 4.years.ago.to_date,
      name: "Balance update",
      amount: 0,
      currency: account.currency,
      entryable: Valuation.new(kind: "reconciliation")
    )

    KrakenAccount::Processor.new(kraken_account).process

    # A fresh instance: the manager memoises the anchor it last read.
    account = Account.find(account.id)
    assert_equal 4.years.ago.to_date.prev_day, account.opening_anchor_date
    assert_equal 0, account.opening_anchor_balance
  end

  # A manual account linked to the exchange later may carry an anchor somebody
  # entered: "this much, on this day". Moving it would change what it says.
  test "leaves an opening anchor with a balance where it is" do
    old_trade = trade_payload("buy", "0.001", "50.00", "0.10").merge("time" => 3.years.ago.to_f)
    kraken_account = @item.kraken_accounts.create!(
      name: "Kraken (linked)", account_id: "linked", account_type: "combined", currency: "USD", current_balance: 50,
      raw_payload: @kraken_account.raw_payload,
      raw_transactions_payload: { "trades" => { "old_tx" => old_trade } }
    )
    account = Account.create_from_kraken_account(kraken_account)
    AccountProvider.create!(account: account, provider: kraken_account)
    account.set_opening_anchor_balance(balance: 250, date: 2.years.ago.to_date)

    KrakenAccount::Processor.new(kraken_account).process

    account = Account.find(account.id)
    assert_equal 2.years.ago.to_date, account.opening_anchor_date
    assert_equal 250, account.opening_anchor_balance
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
