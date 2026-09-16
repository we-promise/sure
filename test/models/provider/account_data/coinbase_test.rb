require "test_helper"

class Provider::AccountData::CoinbaseTest < ActiveSupport::TestCase
  setup do
    @client = mock("Coinbase transport")
    @observed_at = Time.utc(2026, 2, 15, 2)
    @adapter = adapter
    @account = @adapter.normalize_account(wallet)
  end

  test "factory keeps credentials scoped to the connection and uses explicit context" do
    Provider::Coinbase.expects(:new).with(api_key: "key", api_secret: "secret").returns(@client)
    built = Provider::AccountData::Coinbase.build(credentials: { api_key: "key", api_secret: "secret" }, settings: {},
      context: { timezone: "America/Los_Angeles", observed_at: @observed_at,
        external_accounts: [ { external_id: "wallet_1", linked_account: { currency: "EUR" } } ] })

    assert_equal "EUR", built.normalize_account(wallet(native_balance: nil))[:currency]
    assert_equal %w[holdings activities], built.capabilities
    assert_equal [ :external_accounts ], Provider::AccountData::Coinbase.context_sources
    refute Provider::AccountData::Coinbase.native_ready?
    refute_includes built.inspect, "secret"
  end

  test "wallet identity quantity and fiat valuation remain distinct and exact" do
    record = @adapter.normalize_account(wallet(quantity: "0.000000000000000148", native_amount: "9.123456789012345678"))

    assert_equal "wallet_1", record[:external_id]
    assert_equal "Crypto", record[:account_type]
    assert_equal "EUR", record[:currency]
    assert_equal BigDecimal("9.123456789012345678"), record[:balance]
    assert_equal BigDecimal("0"), record[:cash_balance]
    assert_equal "0.000000000000000148", record[:metadata][:asset][:quantity]
    assert_equal "BTC", record[:metadata][:asset][:code]
    assert_equal "Bitcoin", record[:metadata][:asset][:name]
    assert_equal "vault", record[:metadata][:wallet_type]
  end

  test "inventory includes zero wallets and exposes every continuation instead of truncating at one hundred" do
    @client.expects(:get_accounts_page).with(cursor: nil).returns(page([ wallet(quantity: "0", native_balance: nil) ], next_cursor: "/v2/accounts?starting_after=next"))
    first = @adapter.list_accounts
    @client.expects(:get_accounts_page).with(cursor: first.next_cursor).returns(page([]))
    last = @adapter.list_accounts(cursor: first.next_cursor)

    refute first.complete?
    assert_equal BigDecimal("0"), first.records.first[:balance]
    assert_equal "USD", first.records.first[:currency]
    assert last.complete?
  end

  test "native valuation generates the legacy holding identity and family observation date" do
    result = @adapter.fetch_holdings(account: @account)
    holding = result.records.first

    assert_equal "coinbase_wallet_1_2026-02-14", holding[:external_id]
    assert_equal Date.new(2026, 2, 14), holding[:date]
    assert_equal BigDecimal("0.00014884"), holding[:quantity]
    assert_equal (BigDecimal("9.91") / BigDecimal("0.00014884")).round(8), holding[:price]
    assert_equal BigDecimal("9.91"), holding[:amount]
    assert_equal "EUR", holding[:currency]
    assert_equal "CRYPTO:BTC", holding[:security][:ticker]
    assert_equal "ticker_only", holding[:security][:fallback_lookup]
    assert_equal "XCBS", holding[:security][:fallback_exchange_operating_mic]
    assert_equal false, holding[:metadata][:delete_future_holdings]
  end

  test "spot valuation preserves eighteen decimal quantities and stores one captured price for holdings" do
    record = @adapter.normalize_account(wallet(quantity: "0.000000000000000148", native_balance: nil))
    record = with_metadata(record, balance_snapshot_current: false)
    @client.expects(:get_spot_price_page).with("BTC-USD").once.returns(page([ { amount: "66580", currency: "USD" } ]))

    balance = @adapter.fetch_balance(account: record).records.first
    holding = @adapter.fetch_holdings(account: balance).records.first

    assert_equal true, balance[:metadata][:balance_provided]
    assert_equal BigDecimal("0.000000000000000148"), holding[:quantity]
    assert_equal BigDecimal("66580"), holding[:price]
    assert_equal BigDecimal("0"), balance[:balance]
    assert_equal BigDecimal("0"), holding[:amount]
  end

  test "missing native balance uses exact spot value rounded only at the fiat boundary" do
    record = @adapter.normalize_account(wallet(native_balance: nil))
    @client.expects(:get_spot_price_page).with("BTC-USD").returns(page([ { amount: "66580", currency: "USD" } ]))

    balance = @adapter.fetch_balance(account: record).records.first

    assert_equal BigDecimal("9.91"), balance[:balance]
    assert_equal "USD", balance[:currency]
    assert_equal BigDecimal("0"), balance[:cash_balance]
  end

  test "unavailable prices and stale wallet observations cannot overwrite balances with zero" do
    record = @adapter.normalize_account(wallet(native_balance: nil))
    @client.expects(:get_spot_price_page).raises(Provider::Coinbase::ApiError.new("unavailable"))
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_balance(account: record) }

    stale = with_metadata(record, balance_snapshot_current: false, asset_observed_at: (@observed_at - 1.day).iso8601(9))
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_holdings(account: stale) }
  end

  test "zero quantities and explicitly non-crypto linked accounts produce no holdings" do
    zero = @adapter.normalize_account(wallet(quantity: "0", native_amount: "0"))
    non_crypto = with_metadata(@account, linked_account_type: "Investment")

    assert_empty @adapter.fetch_holdings(account: zero).records
    assert_empty @adapter.fetch_holdings(account: non_crypto).records
  end

  test "completed buy and sell identities signs subtotal price and notes match legacy trades" do
    buy = @adapter.normalize_transaction(transaction, account: @account)
    sell = @adapter.normalize_transaction(transaction(type: "sell", amount: "-0.25"), account: @account)

    assert_equal "coinbase_txn_transaction_1", buy[:external_id]
    assert_equal BigDecimal("0.25"), buy[:quantity]
    assert_equal BigDecimal("-12000"), buy[:amount]
    assert_equal BigDecimal("48000"), buy[:price]
    assert_equal BigDecimal("-0.25"), sell[:quantity]
    assert_equal BigDecimal("12000"), sell[:amount]
    assert_equal "EUR", buy[:currency]
    assert_equal "Buy", buy[:metadata][:investment_activity_label]
    assert_equal "insert_only", buy[:metadata][:update_policy]
    assert_equal true, buy[:metadata][:repair_activity_label]
    assert_equal "legacy_1", buy[:metadata][:legacy_buy_sell_id]
    assert_includes buy[:metadata][:notes], "Recurring buy - Bought Bitcoin - From card"
    assert_includes buy[:metadata][:notes], "Visa"
    assert_equal Date.new(2026, 2, 13), buy[:date]
  end

  test "cached legacy buy and sell records keep distinct identities totals and unit prices" do
    raw = { id: "legacy_1", status: "completed", created_at: "2026-02-14T02:00:00Z",
      amount: { amount: "0.000000000000000148", currency: "BTC" }, unit_price: { amount: "66580.12345678" },
      total: { amount: "12.34", currency: "GBP" } }
    buy = @adapter.normalize_legacy_transaction(raw, type: "buy", account: @account)
    sell = @adapter.normalize_legacy_transaction(raw, type: "sell", account: @account)

    assert_equal "coinbase_buy_legacy_1", buy[:external_id]
    assert_equal "coinbase_sell_legacy_1", sell[:external_id]
    assert_equal BigDecimal("0.000000000000000148"), buy[:quantity]
    assert_equal BigDecimal("-0.000000000000000148"), sell[:quantity]
    assert_equal BigDecimal("66580.12345678"), buy[:price]
    assert_equal BigDecimal("-12.34"), buy[:amount]
    assert_equal BigDecimal("12.34"), sell[:amount]
    assert_equal "GBP", sell[:currency]
    assert_equal true, buy[:metadata][:repair_activity_label]
  end

  test "legacy pending payloads stay unposted and malformed completed payloads are visible failures" do
    assert_nil @adapter.normalize_legacy_transaction({ status: "pending" }, type: "buy", account: @account)
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.normalize_legacy_transaction({ status: "completed" }, type: "buy", account: @account)
    end
  end

  test "subtotal overrides only when positive and does not replace the native currency" do
    raw = transaction
    raw[:buy][:subtotal] = { amount: "0", currency: "USD" }
    record = @adapter.normalize_transaction(raw, account: @account)
    assert_equal BigDecimal("-12500.50"), record[:amount]
    assert_equal "EUR", record[:currency]

    raw[:buy][:subtotal] = { amount: "12000", currency: "USD" }
    raw[:native_amount].delete(:currency)
    assert_equal "EUR", @adapter.normalize_transaction(raw, account: @account)[:currency]
  end

  test "pending failed send receive and unsupported transaction types stay outside the old trade projection" do
    [ transaction(status: "pending"), transaction(status: "failed"), transaction(type: "send"),
      transaction(type: "receive"), transaction(type: "staking_reward") ].each do |raw|
      assert_nil @adapter.normalize_transaction(raw, account: @account)
    end
  end

  test "wallet history persists bounded progress and a completed checkpoint restarts discovery" do
    @client.expects(:get_transactions_page).with("wallet_1", cursor: nil).returns(page([ transaction ], next_cursor: "next-uri"))
    first = @adapter.fetch_activities(account: @account)
    @client.expects(:get_transactions_page).with("wallet_1", cursor: "next-uri").returns(page([]))
    last = adapter(observed_at: @observed_at + 1.day).fetch_activities(account: @account, cursor: first.progress_cursor)
    @client.expects(:get_transactions_page).with("wallet_1", cursor: nil).returns(page([]))
    refreshed = @adapter.fetch_activities(account: @account, cursor: last.checkpoint_cursor)

    refute first.complete?
    assert_equal first.next_cursor, first.progress_cursor
    assert_nil first.checkpoint_cursor
    assert last.complete?
    assert_equal @observed_at.iso8601(9), last.coverage["end"]
    assert last.checkpoint_cursor
    assert refreshed.complete?
  end

  test "activity continuation from another wallet is rejected before HTTP" do
    @client.expects(:get_transactions_page).with("wallet_1", cursor: nil).returns(page([], next_cursor: "next-uri"))
    first = @adapter.fetch_activities(account: @account)
    other = @adapter.normalize_account(wallet(id: "wallet_2"))

    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: other, cursor: first.next_cursor) }
  end

  test "an explicit history start persists across pages while generic lookbacks do not truncate history" do
    window = { start: "2026-02-14T08:00:00Z", explicit_start: true }
    @client.expects(:get_transactions_page).returns(page([ transaction ], next_cursor: "next-uri"))
    first = @adapter.fetch_activities(account: @account, window: window)
    @client.expects(:get_transactions_page).returns(page([ transaction ]))
    last = @adapter.fetch_activities(account: @account, cursor: first.next_cursor)
    @client.expects(:get_transactions_page).returns(page([ transaction ]))
    all = @adapter.fetch_activities(account: @account, window: window.merge(explicit_start: false))

    assert_empty first.records
    assert_empty last.records
    assert_equal window[:start], last.coverage["start"]
    assert_equal 1, all.records.size
  end

  test "raw evidence stays in the encrypted batch payload and not the normalized wallet metadata" do
    payload = { data: [ wallet ], private_owner: "private-owner" }
    @client.expects(:get_accounts_page).returns(page([ wallet ]).merge(evidence: payload))

    result = @adapter.list_accounts

    assert_equal payload, result.evidence["response"]
    refute_includes result.records.first[:metadata].to_s, "private-owner"
  end

  test "authorization failures propagate and rate limits cannot complete a partial history" do
    @client.expects(:get_transactions_page).raises(Provider::Coinbase::AuthenticationError.new("scope unavailable"))
    assert_raises(Provider::Coinbase::AuthenticationError) { @adapter.fetch_activities(account: @account) }
    @client.expects(:get_transactions_page).raises(Provider::Coinbase::RateLimitError.new("wait"))
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_activities(account: @account) }
  end

  test "malformed identities dates currencies and exact amounts fail without silent omission" do
    [ transaction(id: nil), transaction(amount: "bad"), transaction(amount: "0"), transaction(amount: 0.25),
      transaction(created_at: "2026-02-30T12:00:00Z"), transaction(created_at: "yesterday") ].each do |raw|
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
    end
    [ wallet(id: nil), wallet(quantity: "NaN"), wallet(quantity: 0.25), wallet(native_currency: "BAD") ].each do |raw|
      assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_account(raw) }
    end
  end

  private
    def adapter(observed_at: @observed_at)
      Provider::AccountData::Coinbase.new(client: @client, timezone: "America/Los_Angeles", observed_at: observed_at)
    end

    def page(items, next_cursor: nil)
      { items: items, next_cursor: next_cursor }
    end

    def wallet(id: "wallet_1", quantity: "0.00014884", native_amount: "9.91", native_currency: "EUR", **overrides)
      { id: id, name: "Bitcoin vault", type: "vault", status: "active",
        balance: { amount: quantity, currency: "BTC" }, currency: { code: "BTC", name: "Bitcoin", type: "crypto" },
        native_balance: { amount: native_amount, currency: native_currency } }.merge(overrides)
    end

    def transaction(id: "transaction_1", type: "buy", status: "completed", amount: "0.25", created_at: "2026-02-14T02:00:00Z")
      { id: id, type: type, status: status, created_at: created_at, description: "Recurring buy",
        details: { title: "Bought Bitcoin", subtitle: "From card" },
        amount: { amount: amount, currency: "BTC" }, native_amount: { amount: "-12500.50", currency: "EUR" },
        type.to_sym => { id: "legacy_1", subtotal: { amount: "12000", currency: "EUR" }, payment_method_name: "Visa" } }
    end

    def with_metadata(record, **values)
      Ingestion::Record.account(**record.attributes.merge(metadata: record[:metadata].merge(values)))
    end
end
