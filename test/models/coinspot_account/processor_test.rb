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
    result = nil
    assert_difference -> { @account.entries.where(source: "coinspot").count }, 9 do
      result = CoinspotAccount::Processor.new(@coinspot_account).process
    end
    assert_equal true, result[:success], result.inspect

    buy = @account.entries.find_by!(external_id: "coinspot_order_buy_BTC_2026-01-02_buy-1", source: "coinspot")
    assert_equal(-100.to_d, buy.amount)
    assert_equal 0.001.to_d, buy.trade.qty
    assert_equal 100_000.to_d, buy.trade.price
    assert_equal "Buy", buy.trade.investment_activity_label

    sell = @account.entries.find_by!(external_id: "coinspot_order_sell_BTC_2026-01-03_sell-1", source: "coinspot")
    assert_equal 220.to_d, sell.amount
    assert_equal(-0.002.to_d, sell.trade.qty)
    assert_equal "Sell", sell.trade.investment_activity_label

    send_record = @coinspot_account.raw_transactions_payload.dig("send_receive", "sendtransactions").first
    fee_digest = Digest::SHA256.hexdigest(CoinspotAccount::Processor.canonical_json(send_record))[0, 24]
    fee = @account.entries.find_by!(external_id: "coinspot_fee_#{fee_digest}", source: "coinspot")
    assert_equal 1.to_d, fee.amount
    assert_equal "Fee", fee.transaction.investment_activity_label

    deposit = @account.entries.find_by!(external_id: "coinspot_deposit_aud_2026-01-06_deposit-1", source: "coinspot")
    assert_equal(-300.to_d, deposit.amount)
    assert_equal "Contribution", deposit.transaction.investment_activity_label

    withdrawal = @account.entries.find_by!(external_id: "coinspot_withdrawal_aud_2026-01-07_withdrawal-1", source: "coinspot")
    assert_equal 150.to_d, withdrawal.amount
    assert_equal "Withdrawal", withdrawal.transaction.investment_activity_label
  end

  test "prices a historical send fee from the transfer instead of the current holdings snapshot" do
    @coinspot_account.update!(
      raw_payload: { "assets" => [] },
      raw_transactions_payload: {
        "send_receive" => {
          "sendtransactions" => [
            { "txid" => "historical-send", "coin" => "btc", "amount" => "0.01", "aud" => "1000", "sendfee" => "0.00001", "timestamp" => "2025-01-04T10:00:00Z" }
          ]
        }
      }
    )

    result = CoinspotAccount::Processor.new(@coinspot_account).process

    assert_equal true, result[:success], result.inspect
    source_record = @coinspot_account.raw_transactions_payload.dig("send_receive", "sendtransactions").first
    digest = Digest::SHA256.hexdigest(CoinspotAccount::Processor.canonical_json(source_record))[0, 24]
    fee = @account.entries.find_by!(external_id: "coinspot_fee_#{digest}")
    assert_equal BigDecimal("1"), fee.amount
  end

  test "rolls back a movement when its native fee has no transaction-date AUD valuation" do
    @coinspot_account.update!(raw_transactions_payload: {
      "send_receive" => {
        "sendtransactions" => [
          { "txid" => "unpriced-fee", "coin" => "btc", "amount" => "0.01", "aud" => "0", "sendfee" => "0.00001", "timestamp" => "2025-01-04T10:00:00Z" }
        ]
      }
    })

    result = CoinspotAccount::Processor.new(@coinspot_account).process

    assert_equal false, result[:success]
    assert_equal "send_receive", result[:failures].first[:kind]
    assert_not @account.entries.exists?(external_id: "coinspot_send_BTC_2025-01-04_unpriced-fee")
  end

  test "rolls back an order when its fee cannot be imported" do
    @coinspot_account.update!(raw_transactions_payload: {
      "orders" => {
        "buyorders" => [ order_payload("atomic-buy", "btc", "0.001", "100.00", "100000.00", "1.00") ]
      }
    })
    processor = CoinspotAccount::Processor.new(@coinspot_account)
    processor.stubs(:import_fee).raises(StandardError, "fee import failed")

    result = processor.process

    assert_equal false, result[:success]
    assert_equal "order", result[:failures].first[:kind]
    assert_not @account.entries.exists?(external_id: "coinspot_order_buy_BTC_2026-01-03_atomic-buy")
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

  test "does not persist an AUD amount under a non-AUD account currency when FX is unavailable" do
    @family.update!(currency: "USD")
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_raises(CoinspotAccount::AudConverter::ConversionUnavailableError) do
      CoinspotAccount::Processor.new(@coinspot_account).process
    end

    @account.reload
    assert_equal 0.to_d, @account.balance
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

  # The whole provider record used to go into DebugLogEntry metadata and into
  # the failure result the syncer surfaces, putting addresses and amounts in
  # front of anyone who can read the debug UI.
  test "a record failure reports only allowlisted fields, not the whole record" do
    @coinspot_account.update!(raw_transactions_payload: {
      "send_receive" => {
        "sendtransactions" => [ {
          "txid" => "send-9", "coin" => "btc", "amount" => "0.001", "aud" => "100.00",
          "timestamp" => "2026-01-04T10:00:00Z",
          "address" => "bc1qsecretdestinationaddress", "sendfee" => "0.00001"
        } ]
      }
    })
    Account::ProviderImportAdapter.any_instance.stubs(:import_transaction).raises(StandardError, "boom")

    result = CoinspotAccount::Processor.new(@coinspot_account).process

    assert_equal false, result[:success]
    record = result[:failures].first[:record]
    assert_equal "send-9", record["txid"]
    assert_equal "btc", record["coin"]
    assert_nil record["address"]
    assert_nil record["aud"]
    assert_nil record["amount"]
    assert_not_includes record.to_json, "bc1qsecretdestinationaddress"
  end

  # ExchangeRate validates presence but not numericality, so a zero or negative
  # rate is storable -- multiplying by one writes a zeroed valuation instead of
  # failing.
  test "refuses to convert with a non-positive exchange rate" do
    @family.update!(currency: "USD")
    ExchangeRate.stubs(:find_or_fetch_rate).returns(
      ExchangeRate.new(from_currency: "AUD", to_currency: "USD", rate: 0, date: Date.current)
    )

    assert_raises(CoinspotAccount::AudConverter::ConversionUnavailableError) do
      CoinspotAccount::Processor.new(@coinspot_account).process
    end

    @account.reload
    assert_equal 0.to_d, @account.balance
    assert_equal "AUD", @account.currency
  end

  test "imports an order without a provider id using a stable content hash" do
    order = {
      "coin" => "btc",
      "amount" => "0.001",
      "audtotal" => "100.00",
      "rate" => "100000.00",
      "created" => "2026-01-09T10:00:00Z"
    }
    @coinspot_account.update!(raw_transactions_payload: { "orders" => { "buyorders" => [ order ] } })

    CoinspotAccount::Processor.new(@coinspot_account).process

    digest = Digest::SHA256.hexdigest(CoinspotAccount::Processor.canonical_json(order))[0, 24]
    assert @account.entries.exists?(external_id: "coinspot_order_buy_BTC_2026-01-09_#{digest}", source: "coinspot")
  end

  # The id-less fallback hashes the record's content, so the same order arriving
  # with its JSON keys in a different order must not import a second time.
  test "an id-less order re-imports as the same entry when its key order changes" do
    order = {
      "coin" => "btc", "amount" => "0.001", "audtotal" => "100.00",
      "rate" => "100000.00", "created" => "2026-01-09T10:00:00Z"
    }
    @coinspot_account.update!(raw_transactions_payload: { "orders" => { "buyorders" => [ order ] } })
    CoinspotAccount::Processor.new(@coinspot_account).process

    reordered = { "created" => "2026-01-09T10:00:00Z", "rate" => "100000.00",
                  "audtotal" => "100.00", "amount" => "0.001", "coin" => "btc" }
    assert_not_equal order.to_json, reordered.to_json
    @coinspot_account.update!(raw_transactions_payload: { "orders" => { "buyorders" => [ reordered ] } })

    assert_no_difference -> { @account.entries.where(source: "coinspot").count } do
      CoinspotAccount::Processor.new(@coinspot_account).process
    end
  end

  # Records imported before canonical hashing keep the id they were stored
  # under, so an upgrade doesn't re-import a family's whole CoinSpot history.
  test "an order already stored under the legacy content hash keeps that id" do
    order = {
      "coin" => "btc", "amount" => "0.001", "audtotal" => "100.00",
      "rate" => "100000.00", "created" => "2026-01-09T10:00:00Z"
    }
    legacy_digest = Digest::SHA256.hexdigest(order.to_json)[0, 24]
    legacy_id = "coinspot_order_buy_BTC_2026-01-09_#{legacy_digest}"
    @account.entries.create!(
      external_id: legacy_id, source: "coinspot", name: "legacy", date: Date.new(2026, 1, 9),
      amount: -100, currency: "AUD",
      entryable: Trade.new(security: @security, qty: 0.001, price: 100_000, currency: "AUD")
    )
    @coinspot_account.update!(raw_transactions_payload: { "orders" => { "buyorders" => [ order ] } })

    assert_no_difference -> { @account.entries.where(source: "coinspot").count } do
      CoinspotAccount::Processor.new(@coinspot_account).process
    end
    assert @account.entries.exists?(external_id: legacy_id, source: "coinspot")
  end

  # A record whose date can't be parsed would be stamped Date.current, and the
  # date is part of every external id -- so the next sync that parses it
  # correctly would import it again instead of updating it.
  test "rejects an order whose timestamp cannot be parsed instead of dating it today" do
    @coinspot_account.update!(raw_transactions_payload: {
      "orders" => { "buyorders" => [ { "id" => "bad-date", "coin" => "btc", "amount" => "0.001",
                                       "audtotal" => "100.00", "created" => "not-a-date" } ] }
    })

    result = nil
    assert_no_difference -> { @account.entries.where(source: "coinspot").count } do
      result = CoinspotAccount::Processor.new(@coinspot_account).process
    end

    assert_equal false, result[:success]
    assert_equal "order", result[:failures].first[:kind]
    assert_equal "CoinspotAccount::Processor::UnparseableTimestampError", result[:failures].first[:error_class]
  end

  # The market-order fallback carries its side per record. Defaulting an
  # unreadable one to "buy" books a sell with the wrong sign on both the
  # quantity and the cash flow.
  test "rejects a market order whose type is missing rather than treating it as a buy" do
    @coinspot_account.update!(raw_transactions_payload: {
      "orders" => { "orders" => [ { "id" => "no-type", "coin" => "btc", "amount" => "0.001",
                                    "audtotal" => "100.00", "created" => "2026-01-09T10:00:00Z" } ] }
    })

    result = nil
    assert_no_difference -> { @account.entries.where(source: "coinspot").count } do
      result = CoinspotAccount::Processor.new(@coinspot_account).process
    end

    assert_equal false, result[:success]
    assert_equal "CoinspotAccount::Processor::UnknownOrderTypeError", result[:failures].first[:error_class]
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
