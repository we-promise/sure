require "test_helper"
require "ostruct"

class Provider::AccountData::KrakenTest < ActiveSupport::TestCase
  setup do
    @client = mock("Kraken transport")
    @observed_at = Time.utc(2026, 1, 31)
    @rates = ->(**) { nil }
    @adapter = build_adapter
    @account = account_record
  end

  test "factory requires explicit atomic nonce and FX dependencies and preserves combined identity" do
    nonce = -> { "1001" }
    client = mock("factory client")
    Provider::Kraken.expects(:new).with(api_key: "private-key", api_secret: "private-secret", nonce_generator: nonce).returns(client)
    adapter = Provider::AccountData::Kraken.build(credentials: { "api_key" => "private-key", "api_secret" => "private-secret" }, settings: {}, context: {
      nonce_generator: nonce, exchange_rate_resolver: @rates, family_currency: "USD", timezone: "UTC", observed_at: @observed_at,
      connection_details: { id: "connection-1" }, external_accounts: [ { external_id: "combined", name: "Existing exchange" } ]
    })
    client.expects(:get_api_key_info_snapshot).returns(envelope("name" => "private API key name"))

    page = adapter.list_accounts

    assert page.complete?
    assert_equal "combined", page.records.sole[:external_id]
    assert_equal "combined", page.records.sole[:account_type]
    assert_equal "Existing exchange", page.records.sole[:name]
    assert_nil page.records.sole[:balance]
    assert_equal "private API key name", page.evidence.fetch("api_key_info").fetch("result").fetch("name")
    refute_includes page.records.sole[:metadata].to_json, "private API key name"
    refute_includes adapter.inspect, "private-key"
    assert_not Provider::AccountData::Kraken.native_ready?
  end

  test "asset symbols preserve legacy suffix identities fiat aliases and available balance calculation" do
    legacy = KrakenAccount::AssetNormalizer.new(asset_metadata)
    native = Provider::AccountData::Kraken::Assets.new(asset_metadata)
    %w[XXBT XBT XETH ZUSD XETH.F XETH.S XXBT.M ZEUR].each do |symbol|
      expected = legacy.normalize(symbol).except(:metadata).stringify_keys
      assert_equal expected, native.normalize(symbol)
    end
    assets = @adapter.parse_assets({ "XXBT" => { "balance" => "1", "credit" => "0.2", "credit_used" => "0.1", "hold_trade" => "0.25" },
      "ZUSD" => { "balance" => "0", "hold_trade" => "0" } }, asset_metadata: asset_metadata)
    assert_equal 1, assets.size
    assert_equal "0.85", assets.sole.fetch("available")
    assert_equal "0.25", assets.sole.fetch("hold_trade")
  end

  test "balance valuation uses a fixed request set and retains encrypted priced assets for following streams" do
    expect_catalogs
    @client.expects(:get_extended_balance_snapshot).once.returns(envelope(
      "XXBT" => { "balance" => "1", "hold_trade" => "0.25" }, "ZUSD" => { "balance" => "50" }))
    @client.expects(:get_ticker_snapshot).once.returns(envelope("XXBTZUSD" => { "c" => [ "50000.123456789012345678" ] }))

    page = @adapter.fetch_balance(account: @account)

    assert page.complete?
    assert_equal BigDecimal("50050.12"), page.records.sole[:balance]
    assert_equal BigDecimal("0"), page.records.sole[:cash_balance]
    valuation = page.records.sole[:sensitive_details][:kraken_valuation]
    assert_equal "50000.123456789012345678", valuation.fetch("assets").first.fetch("price_usd")
    assert_equal "0.75", valuation.fetch("assets").first.fetch("available")
    refute_includes page.records.sole[:metadata].to_json, "50000.123456789012345678"
    assert_equal valuation, Ingestion::Codec.load(Ingestion::Codec.dump(page)).evidence.fetch("valuation")
  end

  test "stablecoin values and per asset rounding retain the legacy aggregate convention" do
    @client.expects(:get_extended_balance_snapshot).returns(envelope(
      "USDT" => { "balance" => "0.006" }, "USDC" => { "balance" => "0.006" }, "ZUSD" => { "balance" => "0.006" }))
    expect_catalogs
    page = @adapter.fetch_balance(account: @account)
    assert page.complete?
    assert_equal BigDecimal("0.03"), page.records.sole[:balance]
    assert_equal [ "1.0" ], page.evidence.fetch("valuation").fetch("assets").map { |asset| asset.fetch("price_usd") }.uniq
  end

  test "missing asset prices preserve unknown balances and raw data instead of writing partial zero totals" do
    expect_catalogs
    @client.expects(:get_extended_balance_snapshot).returns(envelope("XETH.F" => { "balance" => "2" }))
    @client.expects(:get_ticker_snapshot).returns(envelope({}))
    page = @adapter.fetch_balance(account: @account)
    assert_not page.complete?
    assert_nil page.records.sole[:balance]
    assert_equal false, page.records.sole[:metadata][:balance_provided]
    asset = page.evidence.fetch("valuation").fetch("assets").sole
    assert_equal "ETH.F", asset.fetch("symbol")
    assert_nil asset.fetch("amount_usd")
    assert_nil asset.fetch("price_usd")
  end

  test "holdings preserve original dated IDs quantities security fallback and unrounded amounts" do
    raw = priced_asset(balance: "0.5", price_usd: "60000.123456789012345678")
    native = @adapter.normalize_holding(raw)
    imported = nil
    security = OpenStruct.new(id: "original-security")
    KrakenAccount::SecurityResolver.expects(:resolve).with("CRYPTO:BTC", "BTC").returns(security)
    importer = mock("legacy holding boundary")
    importer.expects(:import_holding).with { |**attributes| imported = attributes }
    linked = OpenStruct.new(accountable_type: "Crypto")
    Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
    legacy = OpenStruct.new(current_account: linked, raw_payload: { "assets" => [ raw ] },
      kraken_item: OpenStruct.new(family: OpenStruct.new(currency: "USD")), account_provider: OpenStruct.new(id: "original-link"))
    Time.use_zone("UTC") { travel_to(@observed_at) { KrakenAccount::HoldingsProcessor.new(legacy).process } }

    %i[external_id quantity amount price currency date].each { |key| assert_equal imported[key], native[key] }
    assert_equal "XKRA", native[:security][:fallback_exchange_operating_mic]
    assert_equal "CRYPTO:BTC", native[:security][:ticker]
    assert_equal false, native[:metadata][:delete_future_holdings]
    assert_nil @adapter.normalize_holding(priced_asset(balance: "0"))
  end

  test "current holding snapshot is required and noncrypto accounts remain unsupported" do
    page = @adapter.fetch_holdings(account: @account)
    assert page.complete?
    assert_equal "kraken_BTC_spot_2026-01-31", page.records.sole[:external_id]
    assert_equal false, page.coverage.fetch("absence_authoritative")
    unsupported = @adapter.fetch_holdings(account: account_record(linked_type: "Depository"))
    assert unsupported.complete?
    assert_empty unsupported.records
    assert_equal false, unsupported.coverage.fetch("supported")
    stale = account_record(valuation: valuation.merge("observed_at" => (@observed_at - 1.day).iso8601(9)))
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_holdings(account: stale) }
  end

  test "buy and sell records match persisted legacy trade signs fees notes identity and quantity" do
    financial = families(:dylan_family).accounts.create!(name: "Kraken parity", currency: "USD", balance: 0,
      accountable: Crypto.new(subtype: "exchange"))
    resolved = Security.create!(ticker: "CRYPTO:BTC", name: "BTC parity", exchange_operating_mic: "XKRA", offline: true)
    KrakenAccount::SecurityResolver.stubs(:resolve).returns(resolved)
    legacy = OpenStruct.new(current_account: financial, raw_payload: { "asset_metadata" => asset_metadata, "pair_metadata" => pair_metadata })
    %w[buy sell].each do |type|
      raw = trade(type: type, fee: "0.123456789012345678")
      Time.use_zone("UTC") { KrakenAccount::Processor.new(legacy).send(:process_trade, type, raw) }
      entry = financial.entries.find_by!(source: "kraken", external_id: "kraken_trade_#{type}")
      normalized = @adapter.normalize_trade(type, raw, asset_metadata: asset_metadata, pair_metadata: pair_metadata)
      %i[external_id amount date name currency notes].each do |key|
        actual = key == :notes ? normalized[:metadata][:notes] : normalized[key]
        assert_equal entry.public_send(key), actual
      end
      assert_equal entry.trade.qty, normalized[:quantity]
      assert_equal entry.trade.price, normalized[:price]
      # The source fee remains exact even if the legacy Trade column has lower scale.
      assert_equal BigDecimal("0.123456789012345678"), normalized[:metadata][:fee]
      assert_equal "insert_only", normalized[:metadata][:update_policy]
      assert_equal type.capitalize, normalized[:metadata][:investment_activity_label]
    end
  end

  test "trade pair fallback crypto quote units cost fallback and monetary parsing stay explicit" do
    normalized = @adapter.normalize_trade("btc-quote", trade(pair: "ETHBTC", vol: "2", price: "0.123456789", cost: nil),
      asset_metadata: asset_metadata, pair_metadata: {})
    assert_equal "BTC", normalized[:currency]
    assert_equal "CRYPTO:ETH", normalized[:security][:ticker]
    assert_equal BigDecimal("-0.24691358"), normalized[:amount]
    raw = trade(vol: 0.25, price: 100.5, cost: 25.125, fee: 0.1)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_trade("float", raw, asset_metadata: asset_metadata, pair_metadata: pair_metadata) }
    converted = @adapter.normalize_legacy_trade("float", raw, asset_metadata: asset_metadata, pair_metadata: pair_metadata)
    assert_equal BigDecimal("-25.125"), converted[:amount]
    assert_equal BigDecimal("0.1"), converted[:metadata][:fee]
  end

  test "cash ledgers preserve fee impact labels excluded movements and legacy external IDs" do
    cases = { "deposit" => [ "100", "1", "-99", "Contribution", "funds_movement" ],
      "withdrawal" => [ "-500", "1", "501", "Withdrawal", "funds_movement" ],
      "staking" => [ "10", "0", "-10", "Dividend", "standard" ],
      "earn" => [ "5", "0", "-5", "Interest", "standard" ], "fee" => [ "-7.5", "0", "7.5", "Fee", "standard" ] }
    cases.each do |type, (amount, fee, expected, label, kind)|
      raw = ledger(type: type, amount: amount, fee: fee)
      record = @adapter.normalize_ledger(type, raw, valuation: valuation)
      assert_equal "kraken_ledger_#{type}", record[:external_id]
      assert_equal BigDecimal(expected), record[:amount]
      assert_equal label, record[:metadata][:investment_activity_label]
      assert_equal kind, record[:metadata][:kind]
      assert_equal raw["amount"], record[:metadata][:extra]["kraken"]["raw_amount"]
      assert_equal raw["fee"], record[:metadata][:extra]["kraken"]["fee_native"]
      assert_equal "insert_only", record[:metadata][:update_policy]
      assert_equal false, record[:metadata][:pending_provided]
    end
    %w[trade transfer margin rollover settled adjustment unsupported].each do |type|
      assert_nil @adapter.normalize_ledger("ignored", ledger(type: type), valuation: valuation)
    end
    %w[allocation deallocation].each do |subtype|
      assert_nil @adapter.normalize_ledger("internal", ledger(type: "earn", subtype: subtype), valuation: valuation)
    end
  end

  test "ledger crypto prices use the captured current asset quote and FX uses the historical event date" do
    calls = []
    adapter = build_adapter(currency: "EUR", exchange_rate_resolver: ->(**request) {
      calls << request
      { rate: BigDecimal("0.923456789012345678"), date: "2026-01-14" }
    })
    raw = ledger(asset: "XXBT", amount: "0.1", time: Time.utc(2026, 1, 15).to_i)
    record = adapter.normalize_ledger("deposit", raw, valuation: valuation)
    assert_equal BigDecimal("-5000") * BigDecimal("0.923456789012345678"), record[:amount]
    assert_equal "EUR", record[:currency]
    assert_equal [ { from: "USD", to: "EUR", date: Date.new(2026, 1, 15) } ], calls
    assert_equal true, record[:metadata][:extra]["kraken"]["price_missing"]
    assert_raises(Provider::AccountData::Kraken::MissingValuation) do
      @adapter.normalize_ledger("unpriced", ledger(asset: "XETH", amount: "1"), valuation: valuation)
    end
    assert_raises(Provider::AccountData::Kraken::MissingValuation) do
      build_adapter(currency: "EUR").normalize_ledger("no-fx", ledger, valuation: valuation)
    end
  end

  test "ledger Page records the exact FX request and actual rate date for durable replay" do
    adapter = build_adapter(currency: "EUR", exchange_rate_resolver: ->(**) { { rate: BigDecimal("0.92"), date: "2026-01-14" } })
    @client.expects(:get_ledgers_page).with(start: nil, end_at: @observed_at.to_i, offset: 0)
      .returns(envelope("ledger" => { "deposit" => ledger }, "count" => 1))
    page = adapter.fetch_transactions(account: @account)
    assert page.complete?
    rate = Ingestion::Codec.load(Ingestion::Codec.dump(page)).evidence.fetch("exchange_rates").sole
    assert_equal "2026-01-15", rate.fetch("requested_date")
    assert_equal({ "rate" => BigDecimal("0.92"), "date" => "2026-01-14" }, rate.fetch("result"))
    assert_equal valuation, page.evidence.fetch("valuation")
  end

  test "history uses bounded stable end offset pages and defaults to complete history instead of ninety days" do
    expect_catalogs
    first_rows = 50.times.to_h { |index| [ "trade-#{index}", trade ] }
    @client.expects(:get_trades_history_page).with(start: nil, end_at: @observed_at.to_i, offset: 0)
      .returns(envelope("trades" => first_rows, "count" => 51))
    @client.expects(:get_trades_history_page).with(start: nil, end_at: @observed_at.to_i, offset: 50)
      .returns(envelope("trades" => { "last-trade" => trade }, "count" => 51))
    window = { start: (@observed_at - 90.days).iso8601, end: @observed_at.iso8601, explicit_start: false }

    first = @adapter.fetch_activities(account: @account, window: window)
    second = @adapter.fetch_activities(account: @account, cursor: first.next_cursor, window: window)

    assert_not first.complete?
    assert_equal first.next_cursor, first.progress_cursor
    assert second.complete?
    assert_nil second.progress_cursor
    assert_equal 51, first.records.size + second.records.size
    assert_equal "all_history", second.coverage.fetch("scope")
    assert_equal "delta", second.mode
  end

  test "short pages count changes repeated IDs and unpriced rows are partial rather than completed history" do
    @client.expects(:get_ledgers_page).returns(envelope("ledger" => { "short" => ledger }, "count" => 100))
    partial = @adapter.fetch_transactions(account: @account)
    assert_not partial.complete?
    assert_nil partial.next_cursor
    @client.expects(:get_ledgers_page).returns(envelope("ledger" => { "missing-price" => ledger(asset: "XETH") }, "count" => 1))
    unpriced = @adapter.fetch_transactions(account: @account)
    assert_not unpriced.complete?
    assert_empty unpriced.records
    assert_equal "missing_ledger_valuation", unpriced.warnings.sole.fetch("code")

    first_rows = 50.times.to_h { |index| [ "entry-#{index}", ledger ] }
    @client.expects(:get_ledgers_page).returns(envelope("ledger" => first_rows, "count" => 51))
    first = @adapter.fetch_transactions(account: @account)
    @client.expects(:get_ledgers_page).returns(envelope("ledger" => { "entry-0" => ledger }, "count" => 52))
    changed = @adapter.fetch_transactions(account: @account, cursor: first.next_cursor)
    assert_not changed.complete?
    assert_nil changed.progress_cursor
    assert_includes changed.warnings.map { |warning| warning.fetch("code") }, "history_count_changed"
    assert_includes changed.warnings.map { |warning| warning.fetch("code") }, "repeated_history_rows"
  end

  test "history request budget checkpoints progress and resumes in a fresh adapter with the original end bound" do
    cursor = nil
    20.times do |page|
      rows = 50.times.to_h { |index| [ "entry-#{page}-#{index}", ledger(type: "transfer") ] }
      @client.expects(:get_ledgers_page).with(start: nil, end_at: @observed_at.to_i, offset: page * 50)
        .returns(envelope("ledger" => rows, "count" => 1001))
      result = @adapter.fetch_transactions(account: @account, cursor: cursor)
      cursor = result.progress_cursor
      assert cursor.present?
    end
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_transactions(account: @account, cursor: cursor) }
    @client.expects(:get_ledgers_page).with(start: nil, end_at: @observed_at.to_i, offset: 1000)
      .returns(envelope("ledger" => { "final" => ledger }, "count" => 1001))
    resumed = build_adapter.fetch_transactions(account: @account, cursor: cursor)
    assert resumed.complete?
    assert_equal 1, resumed.records.size
    assert_equal @observed_at.iso8601, resumed.coverage.fetch("end")
  end

  test "history cursors cannot switch connection resource or target denomination" do
    rows = 50.times.to_h { |index| [ "entry-#{index}", ledger ] }
    @client.expects(:get_ledgers_page).returns(envelope("ledger" => rows, "count" => 51))
    first = @adapter.fetch_transactions(account: @account)
    [ build_adapter(connection_id: "other"), build_adapter(currency: "EUR") ].each do |adapter|
      assert_raises(Provider::AccountData::InvalidResponse) { adapter.fetch_transactions(account: @account, cursor: first.next_cursor) }
    end
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: @account, cursor: first.next_cursor) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_transactions(account: @account, cursor: "malformed") }
  end

  private
    def build_adapter(**attributes)
      Provider::AccountData::Kraken.new(**{ client: @client, currency: "USD", timezone: "UTC", observed_at: @observed_at,
        exchange_rate_resolver: @rates, connection_id: "connection-1" }.merge(attributes))
    end

    def account_record(valuation: self.valuation, linked_type: "Crypto")
      Ingestion::Record.account(external_id: "combined", name: "Kraken", currency: "USD", account_type: "combined",
        metadata: { linked_account_type: linked_type }, sensitive_details: { kraken_valuation: valuation })
    end

    def valuation
      { "schema_version" => 1, "observed_at" => @observed_at.iso8601(9), "assets" => [ priced_asset ],
        "asset_metadata" => asset_metadata, "pair_metadata" => pair_metadata }
    end

    def priced_asset(**attributes)
      { "symbol" => "BTC", "price_symbol" => "BTC", "balance" => "1", "price_usd" => "50000", "amount_usd" => "50000", "source" => "spot" }.merge(attributes.stringify_keys)
    end

    def asset_metadata
      { "XXBT" => { "altname" => "XBT" }, "XETH" => { "altname" => "ETH" }, "ZUSD" => { "altname" => "USD" } }
    end

    def pair_metadata
      { "XXBTZUSD" => { "altname" => "XBTUSD", "base" => "XXBT", "quote" => "ZUSD" } }
    end

    def expect_catalogs
      @client.expects(:get_asset_info_snapshot).once.returns(envelope(asset_metadata))
      @client.expects(:get_asset_pairs_snapshot).once.returns(envelope(pair_metadata))
    end

    def trade(**attributes)
      { "ordertxid" => "order-1", "pair" => "XBTUSD", "time" => Time.utc(2026, 1, 15).to_i,
        "type" => "buy", "vol" => "0.001", "price" => "50000", "cost" => "50", "fee" => "0.1" }.merge(attributes.stringify_keys)
    end

    def ledger(**attributes)
      { "refid" => "reference-1", "time" => Time.utc(2026, 1, 15).to_i, "type" => "deposit", "subtype" => "",
        "asset" => "ZUSD", "amount" => "100", "fee" => "0", "balance" => "1000" }.merge(attributes.stringify_keys)
    end

    def envelope(result)
      { "error" => [], "result" => result }
    end
end
