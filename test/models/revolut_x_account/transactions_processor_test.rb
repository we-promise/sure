# frozen_string_literal: true

require "test_helper"

class RevolutXAccount::TransactionsProcessorTest < ActiveSupport::TestCase
  # 2023-11-14T22:13:20Z
  CREATED_MS = 1_700_000_000_000
  DATE = Date.new(2023, 11, 14)

  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = @family.revolut_x_items.create!(name: "Revolut X", api_key: "a1" * 32, transactions_synced_through: Time.current)
    @revolut_x_account = @item.revolut_x_accounts.create!(
      name: "Revolut X", account_id: "default", account_type: "exchange", currency: "USD", current_balance: 0
    )
    @account = @family.accounts.create!(name: "Revolut X", balance: 0, currency: "USD", accountable: Crypto.new)
    AccountProvider.create!(account: @account, provider: @revolut_x_account)
    @revolut_x_account.reload
    Security.any_instance.stubs(:import_provider_prices).returns(0)
  end

  test "buy paid from outside the exchange: Trade plus a funding Transaction" do
    process tx("b1", "buy", source: leg("1000.00", "USD", "revolut"), destination: leg("0.01", "BTC"))

    trade = entry("revolut_x_b1")
    assert_trade trade, ticker: "CRYPTO:BTC", qty: 0.01, amount: 1000, currency: "USD", label: "Buy"
    assert_equal 100_000, trade.entryable.price

    funding = entry("revolut_x_b1_funding")
    assert_transaction funding, amount: -1000, currency: "USD", label: "Contribution", kind: "investment_contribution"
    assert_equal "revolut", funding.entryable.extra.dig("revolut_x", "source_account_type")
    assert_equal "revolut_x", funding.entryable.extra.dig("revolut_x", "destination_account_type")
  end

  test "buy paid from exchange cash: Trade only" do
    process tx("b2", "buy", source: leg("1000.00", "USD"), destination: leg("0.01", "BTC"))

    assert_trade entry("revolut_x_b2"), ticker: "CRYPTO:BTC", qty: 0.01, amount: 1000, currency: "USD", label: "Buy"
    assert_equal 1, @account.entries.count
  end

  test "sell paid out to outside the exchange: Trade plus a funding Transaction" do
    process tx("s1", "sell", source: leg("0.5", "ETH"), destination: leg("1500.00", "EUR", "revolut"))

    assert_trade entry("revolut_x_s1"), ticker: "CRYPTO:ETH", qty: -0.5, amount: -1500, currency: "EUR", label: "Sell"
    assert_transaction entry("revolut_x_s1_funding"), amount: 1500, currency: "EUR", label: "Withdrawal", kind: "funds_movement"
  end

  test "sell into exchange cash: Trade only" do
    process tx("s2", "sell", source: leg("0.5", "ETH"), destination: leg("1500.00", "EUR"))

    assert_trade entry("revolut_x_s2"), ticker: "CRYPTO:ETH", qty: -0.5, amount: -1500, currency: "EUR", label: "Sell"
    assert_equal 1, @account.entries.count
  end

  test "crypto to crypto: an out and an in Trade, both amount 0" do
    process tx("x1", "buy", source: leg("2", "ETH"), destination: leg("0.1", "BTC"))

    assert_trade entry("revolut_x_x1_out"), ticker: "CRYPTO:ETH", qty: -2, amount: 0, currency: "USD", label: "Sell"
    assert_trade entry("revolut_x_x1_in"), ticker: "CRYPTO:BTC", qty: 0.1, amount: 0, currency: "USD", label: "Buy"
  end

  test "a buy or sell whose crypto leg is elsewhere, or that is fiat to fiat, creates nothing and is reported" do
    assert_difference -> { DebugLogEntry.where(provider_key: "revolut_x").count }, 2 do
      process(
        tx("u1", "buy", source: leg("1000", "USD"), destination: leg("0.01", "BTC", "external_crypto_wallet")),
        tx("u2", "sell", source: leg("100", "EUR"), destination: leg("110", "USD"))
      )
    end

    assert_equal 0, @account.entries.count
  end

  test "receive crypto: Trade in, amount 0, Transfer" do
    process tx("r1", "receive", source: leg("1", "BTC", "external_crypto_wallet"), destination: leg("1", "BTC"))

    assert_trade entry("revolut_x_r1"), ticker: "CRYPTO:BTC", qty: 1, amount: 0, currency: "USD", label: "Transfer"
  end

  test "receive fiat: inflow Transaction, Contribution" do
    process tx("r2", "receive", source: leg("250", "EUR", "revolut"), destination: leg("250", "EUR"))

    assert_transaction entry("revolut_x_r2"), amount: -250, currency: "EUR", label: "Contribution", kind: "investment_contribution"
  end

  test "send crypto: Trade out, amount 0, Transfer" do
    process tx("o1", "send", source: leg("0.5", "BTC"), destination: leg("0.5", "BTC", "external_crypto_wallet"))

    assert_trade entry("revolut_x_o1"), ticker: "CRYPTO:BTC", qty: -0.5, amount: 0, currency: "USD", label: "Transfer"
  end

  test "send fiat: outflow Transaction, Withdrawal" do
    process tx("o2", "send", source: leg("300", "USD"), destination: leg("300", "USD", "revolut"))

    assert_transaction entry("revolut_x_o2"), amount: 300, currency: "USD", label: "Withdrawal", kind: "funds_movement"
  end

  test "reward crypto: Trade in, amount 0, Dividend" do
    process tx("w1", "reward", destination: leg("0.005", "ETH"))

    trade = entry("revolut_x_w1")
    assert_trade trade, ticker: "CRYPTO:ETH", qty: 0.005, amount: 0, currency: "USD", label: "Dividend"
    assert_nil trade.entryable.extra.dig("revolut_x", "source_account_type")
    assert_equal "revolut_x", trade.entryable.extra.dig("revolut_x", "destination_account_type")
  end

  test "reward fiat: inflow Transaction, standard, Dividend" do
    process tx("w2", "reward", destination: leg("4.20", "EUR"))

    assert_transaction entry("revolut_x_w2"), amount: -4.2, currency: "EUR", label: "Dividend", kind: "standard"
  end

  test "an amount-0 Trade takes the stored price for its day, and flags a missing one" do
    eth = Onchain::SecurityResolver.resolve(symbol: "ETH")
    eth.prices.create!(date: DATE, price: 2000, currency: "USD")

    process(
      tx("p1", "reward", destination: leg("1", "ETH")),
      tx("p2", "reward", destination: leg("1", "SOL"))
    )

    assert_equal 2000, entry("revolut_x_p1").entryable.price
    assert_nil entry("revolut_x_p1").entryable.extra.dig("revolut_x", "price_missing")
    assert_equal 0, entry("revolut_x_p2").entryable.price
    assert_equal true, entry("revolut_x_p2").entryable.extra.dig("revolut_x", "price_missing")
  end

  test "an amount-0 Trade converts its price at that day's rate" do
    @family.update!(currency: "EUR")
    Onchain::SecurityResolver.resolve(symbol: "ETH").prices.create!(date: DATE, price: 2000, currency: "USD")
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: DATE, rate: 0.9)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.5)

    process tx("p3", "reward", destination: leg("1", "ETH"))

    assert_equal 1800, entry("revolut_x_p3").entryable.price
  end

  test "rows are written oldest first, whatever order they were stored in" do
    process(
      tx("t_sell", "sell", source: leg("0.01", "BTC"), destination: leg("1100", "USD"), created_ms: CREATED_MS + 3_600_000),
      tx("t_buy", "buy", source: leg("1000", "USD"), destination: leg("0.01", "BTC"))
    )

    assert_operator entry("revolut_x_t_buy").created_at, :<, entry("revolut_x_t_sell").created_at
  end

  test "a completed row never takes over another row's pending entry of the same amount" do
    pending = tx("a1", "send", status: "pending", source: leg("300", "USD"))
    process pending

    process pending, tx("a2", "send", source: leg("300", "USD"), created_ms: CREATED_MS + 86_400_000)

    assert entry("revolut_x_a1").entryable.pending?
    assert_not entry("revolut_x_a2").entryable.pending?
    assert_equal 2, @account.entries.count
  end

  test "stake and un_stake rows create nothing and leave balance and holdings alone" do
    @account.update!(balance: 5000)
    btc = Onchain::SecurityResolver.resolve(symbol: "BTC")
    holding = @account.holdings.create!(security: btc, date: Date.current, qty: 2, price: 2500, amount: 5000, currency: "USD")

    process(
      tx("k1", "stake", source: leg("1", "BTC")),
      tx("k2", "un_stake", destination: leg("1", "BTC"))
    )

    assert_equal 0, @account.entries.count
    assert_equal 5000, @account.reload.balance
    assert_equal 2, holding.reload.qty
  end

  test "a pending fiat send is a pending Transaction until it completes" do
    process tx("q1", "send", status: "pending", source: leg("300", "USD"), destination: leg("300", "USD", "revolut"))

    pending = entry("revolut_x_q1")
    assert pending.entryable.pending?
    assert_equal true, pending.entryable.extra.dig("revolut_x", "pending")

    process tx("q1", "send", source: leg("300", "USD"), destination: leg("300", "USD", "revolut"))

    completed = entry("revolut_x_q1")
    assert_equal pending.id, completed.id
    assert_not completed.entryable.pending?
    assert_equal "completed", completed.entryable.extra.dig("revolut_x", "status")
  end

  test "a pending crypto send waits until it completes" do
    process tx("q2", "send", status: "pending", source: leg("0.5", "BTC"), destination: leg("0.5", "BTC", "external_crypto_wallet"))
    assert_equal 0, @account.entries.count

    process tx("q2", "send", source: leg("0.5", "BTC"), destination: leg("0.5", "BTC", "external_crypto_wallet"))
    assert_trade entry("revolut_x_q2"), ticker: "CRYPTO:BTC", qty: -0.5, amount: 0, currency: "USD", label: "Transfer"
  end

  test "cancelled, failed and reverted rows create nothing" do
    process(*%w[cancelled failed reverted].map { |status| tx("v_#{status}", "receive", status: status, destination: leg("1", "BTC")) })

    assert_equal 0, @account.entries.count
  end

  test "a cancelled row removes its earlier pending entry, unless the user edited it" do
    process(
      tx("c1", "send", status: "pending", source: leg("10", "USD")),
      tx("c2", "send", status: "pending", source: leg("20", "USD"))
    )
    entry("revolut_x_c2").update!(user_modified: true)

    process(
      tx("c1", "send", status: "cancelled", source: leg("10", "USD")),
      tx("c2", "send", status: "cancelled", source: leg("20", "USD"))
    )

    assert_nil entry("revolut_x_c1")
    assert entry("revolut_x_c2")
  end

  test "processing the same payload twice creates no duplicates" do
    rows = [
      tx("d1", "buy", source: leg("1000", "USD", "revolut"), destination: leg("0.01", "BTC")),
      tx("d2", "buy", source: leg("2", "ETH"), destination: leg("0.1", "BTC")),
      tx("d3", "receive", destination: leg("50", "USD"))
    ]
    process(*rows)

    assert_no_difference -> { @account.entries.count } do
      process(*rows)
    end
    assert_equal 5, @account.entries.count
  end

  test "nothing is written before the first history walk completes" do
    @item.update!(transactions_synced_through: nil)

    process tx("b1", "buy", source: leg("1000.00", "USD"), destination: leg("0.01", "BTC"))

    assert_equal 0, @account.entries.count
  end

  test "rows wait until a history walk completes, then a same-day buy is written before its sell" do
    buy = tx("b1", "buy", source: leg("1000.00", "USD"), destination: leg("0.01", "BTC"))
    sell = tx("s1", "sell", source: leg("0.01", "BTC"), destination: leg("1100.00", "USD"), created_ms: CREATED_MS + 60_000)
    interrupted_at = @item.transactions_synced_through + 1.hour
    @revolut_x_account.update!(raw_transactions_payload: { "transactions" => { "s1" => sell }, "fetched_at" => interrupted_at.iso8601 })

    RevolutXAccount::TransactionsProcessor.new(@revolut_x_account).process
    assert_equal 0, @account.entries.count

    @item.update!(transactions_synced_through: interrupted_at + 1.hour)
    @revolut_x_account.reload.update!(raw_transactions_payload: {
      "transactions" => { "s1" => sell, "b1" => buy }, "fetched_at" => (interrupted_at + 1.hour).iso8601
    })
    RevolutXAccount::TransactionsProcessor.new(@revolut_x_account).process

    assert_operator entry("revolut_x_b1").created_at, :<, entry("revolut_x_s1").created_at
  end

  test "a same-day trade after a pending trade waits, so the pending one is written first" do
    send_pending = tx("o1", "send", status: "pending", source: leg("0.5", "BTC"), destination: leg("0.5", "BTC", "external_crypto_wallet"))
    earlier = tx("b0", "buy", source: leg("500", "USD"), destination: leg("0.01", "BTC"), created_ms: CREATED_MS - 60_000)
    buy = tx("b1", "buy", source: leg("30000", "USD"), destination: leg("0.5", "BTC"), created_ms: CREATED_MS + 60_000)
    fiat = tx("f1", "receive", source: leg("50", "USD", "revolut"), destination: leg("50", "USD"), created_ms: CREATED_MS + 120_000)
    next_day = tx("n1", "buy", source: leg("1000", "USD"), destination: leg("0.01", "BTC"), created_ms: CREATED_MS + 86_400_000)

    process send_pending, earlier, buy, fiat, next_day

    assert entry("revolut_x_b0"), "a trade before the pending one is written"
    assert entry("revolut_x_f1"), "a fiat-only row is not held back"
    assert entry("revolut_x_n1"), "another day is not held back"
    assert_nil entry("revolut_x_o1")
    assert_nil entry("revolut_x_b1")

    process send_pending.merge("status" => "completed"), earlier, buy, fiat, next_day

    assert_operator entry("revolut_x_o1").created_at, :<, entry("revolut_x_b1").created_at
  end

  test "the spec's paginated example end to end" do
    payload = JSON.parse(file_fixture("revolut_x/transactions.json").read)
    store(payload["data"])

    RevolutXAccount::TransactionsProcessor.new(@revolut_x_account).process

    buy = entry("revolut_x_a1b2c3d4-e5f6-7890-abcd-ef0123456789")
    assert_trade buy, ticker: "CRYPTO:BTC", qty: 0.01, amount: 1000, currency: "USD", label: "Buy"
    assert_transaction entry("revolut_x_a1b2c3d4-e5f6-7890-abcd-ef0123456789_funding"),
      amount: -1000, currency: "USD", label: "Contribution", kind: "investment_contribution"
    assert_trade entry("revolut_x_b2c3d4e5-f6a7-8901-bcde-f12345678901"),
      ticker: "CRYPTO:ETH", qty: 0.005, amount: 0, currency: "USD", label: "Dividend"
    assert_nil entry("revolut_x_c3d4e5f6-a7b8-9012-cdef-234567890123")
    assert_equal 3, @account.entries.count
  end

  private

    def process(*rows)
      store(rows)
      RevolutXAccount::TransactionsProcessor.new(@revolut_x_account).process
    end

    def store(rows)
      @revolut_x_account.update!(raw_transactions_payload: { "transactions" => rows.index_by { |row| row["id"] } })
    end

    def tx(id, type, status: "completed", source: nil, destination: nil, created_ms: CREATED_MS)
      { "id" => id, "status" => status, "type" => type, "source" => source, "destination" => destination, "created_date" => created_ms }.compact
    end

    def leg(amount, currency, account_type = "revolut_x")
      { "amount" => amount, "currency" => currency, "account" => { "type" => account_type } }
    end

    def entry(external_id)
      @account.entries.find_by(external_id: external_id, source: "revolut_x")
    end

    def assert_trade(entry, ticker:, qty:, amount:, currency:, label:)
      assert entry, "expected a trade entry"
      trade = entry.entryable
      assert_kind_of Trade, trade
      assert_equal ticker, trade.security.ticker
      assert_equal qty.to_d, trade.qty
      assert_equal amount.to_d, entry.amount
      assert_equal currency, entry.currency
      assert_equal label, trade.investment_activity_label
      assert_equal DATE, entry.date
      assert_account_types entry
    end

    def assert_transaction(entry, amount:, currency:, label:, kind:)
      assert entry, "expected a transaction entry"
      transaction = entry.entryable
      assert_kind_of Transaction, transaction
      assert_equal amount.to_d, entry.amount
      assert_equal currency, entry.currency
      assert_equal label, transaction.investment_activity_label
      assert_equal kind, transaction.kind
      assert_equal DATE, entry.date
      assert_account_types entry
    end

    def assert_account_types(entry)
      meta = entry.entryable.extra["revolut_x"]
      assert meta.key?("source_account_type")
      assert meta.key?("destination_account_type")
    end
end
