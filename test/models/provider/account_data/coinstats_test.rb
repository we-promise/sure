require "test_helper"
require "ostruct"

class Provider::AccountData::CoinstatsTest < ActiveSupport::TestCase
  setup do
    @client = mock("CoinStats reader")
    @observed_at = Time.utc(2026, 9, 15, 12)
    @rates = ->(**) { nil }
    @descriptor = descriptor
    @account = account_record
    @adapter = build_adapter
  end

  test "factory uses reviewed external descriptors and preserves case-sensitive composite identities" do
    Provider::Coinstats::IngestionClient.expects(:new).with(api_key: "private-api-key").returns(@client)
    adapter = Provider::AccountData::Coinstats.build(credentials: { "api_key" => "private-api-key" }, settings: {}, context: {
      external_accounts: [ @account.attributes ], exchange_rate_resolver: @rates, timezone: "UTC", family_currency: "USD", observed_at: @observed_at
    })
    @client.expects(:wallet_balances).never
    page = adapter.list_accounts
    assert page.complete?
    assert_nil page.records.sole[:balance]
    assert_equal @account[:external_id], page.records.sole[:external_id]
    assert_equal "0xABC", page.records.sole[:sensitive_details][:source_descriptor].fetch("wallet_address")
    assert_equal false, page.coverage.fetch("absence_authoritative")
    refute_includes page.records.sole[:metadata].to_json, "0xABC"
    refute_includes adapter.inspect, "private-api-key"
    assert_not Provider::AccountData::Coinstats.native_ready?
  end

  test "inventory rejects unreviewed ambiguous or rebound source descriptors" do
    invalid = @account.attributes.deep_dup
    invalid[:external_id] = invalid[:external_id].downcase
    adapter = build_adapter(external_accounts: [ invalid ])
    page = adapter.list_accounts
    assert_not page.complete?
    assert_empty page.records
    assert_equal "account_source_descriptor_invalid", page.warnings.sole.fetch("code")
    assert_raises(Provider::AccountData::InvalidResponse) { adapter.fetch_balance(account: Ingestion::Record.account(**invalid)) }
  end

  test "wallet balance and holdings keep exact quantity price and original holding identity" do
    @client.expects(:wallet_balances).with(address: "0xABC", blockchain: "ethereum").once.returns(wallet_response(
      { "coinId" => "ethereum", "symbol" => "ETH", "name" => "Ethereum", "amount" => "0.123456789012345678", "price" => "2000.123456789012345678" }))
    page = @adapter.fetch_balance(account: @account)
    balance = BigDecimal("0.123456789012345678") * BigDecimal("2000.123456789012345678")
    assert page.complete?
    assert_equal balance, page.records.sole[:balance]
    assert_equal BigDecimal("0"), page.records.sole[:cash_balance]
    assert_equal "USD", page.records.sole[:currency]
    assert_equal "balance_date", page.records.sole[:metadata][:balance_policy][:anchor_date]
    holding = @adapter.fetch_holdings(account: @account).records.sole
    assert_equal "coinstats_holding_ethereum_2026-09-15", holding[:external_id]
    assert_equal BigDecimal("0.123456789012345678"), holding[:quantity]
    assert_equal BigDecimal("2000.123456789012345678"), holding[:price]
    assert_equal balance, holding[:amount]
    assert_equal "CRYPTO:ETH", holding[:security][:ticker]
    assert_equal false, holding[:metadata][:delete_future_holdings]
    assert_equal page.evidence, Ingestion::Codec.load(Ingestion::Codec.dump(page)).evidence
  end

  test "wallet routing requires the exact requested address and asset instead of matching an account name" do
    wrong_wallet = wallet_response(wallet_coin)
    wrong_wallet.first["address"] = "0xabc"
    @client.expects(:wallet_balances).returns(wrong_wallet)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: @account) }
    adapter = build_adapter
    @client.expects(:wallet_balances).returns(wallet_response(wallet_coin.merge("coinId" => "ethereum-classic")))
    assert_raises(Provider::AccountData::InvalidResponse) { adapter.fetch_balance(account: @account) }
  end

  test "missing price does not publish an invented zero balance" do
    @client.expects(:wallet_balances).returns(wallet_response(wallet_coin.except("price")))
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: @account) }
  end

  test "fiat source writes cash units without creating a crypto holding" do
    descriptor = descriptor(asset_id: "FiatCoinUSD", symbol: "USD", fiat: true)
    account = account_record(descriptor: descriptor)
    adapter = build_adapter(external_accounts: [ account.attributes ])
    @client.expects(:wallet_balances).returns(wallet_response("coinId" => "FiatCoinUSD", "symbol" => "USD", "amount" => "50.12", "isFiat" => true))
    page = adapter.fetch_balance(account: account)
    assert_equal BigDecimal("50.12"), page.records.sole[:balance]
    assert_equal BigDecimal("50.12"), page.records.sole[:cash_balance]
    assert_empty adapter.fetch_holdings(account: account).records
  end

  test "exchange pages stage all coin components before publishing the aggregate" do
    descriptor = exchange_descriptor
    account = account_record(descriptor: descriptor)
    adapter = build_adapter(external_accounts: [ account.attributes ])
    coins = 100.times.map { |index| portfolio_coin(identifier: "coin-#{index}", symbol: "T#{index}") }
    @client.expects(:portfolio_coins).with(portfolio_id: "portfolio-1", page: 1).returns(envelope(coins, page: 1))
    first = adapter.fetch_balance(account: account)
    assert_not first.complete?
    assert_empty first.records
    assert_equal first.next_cursor, first.progress_cursor
    @client.expects(:portfolio_coins).with(portfolio_id: "portfolio-1", page: 2).returns(envelope([ portfolio_coin(identifier: "FiatCoinUSD", symbol: "USD", count: "25", is_fiat: true) ], page: 2))
    final = adapter.fetch_balance(account: account, cursor: first.next_cursor)
    assert final.complete?
    assert_equal BigDecimal("125"), final.records.sole[:balance]
    assert_equal BigDecimal("25"), final.records.sole[:cash_balance]
    holdings = adapter.fetch_holdings(account: account)
    assert_equal 100, holdings.records.size
    assert_equal "coinstats_holding_portfolio:portfolio-1_coin-0_2026-09-15", holdings.records.first[:external_id]
    assert_equal false, holdings.coverage.fetch("absence_authoritative")
    assert_equal true, holdings.coverage.fetch("legacy_same_day_pruning")
  end

  test "resumed balance cursor is bound to the original route and retains exact coins" do
    descriptor = exchange_descriptor
    account = account_record(descriptor: descriptor)
    adapter = build_adapter(external_accounts: [ account.attributes ])
    coins = 100.times.map { |index| portfolio_coin(identifier: "coin-#{index}", symbol: "T#{index}", count: BigDecimal("0.123456789012345678")) }
    @client.expects(:portfolio_coins).returns(envelope(coins, page: 1))
    first = adapter.fetch_balance(account: account)
    resumed = build_adapter(external_accounts: [ account.attributes ])
    @client.expects(:portfolio_coins).with(portfolio_id: "portfolio-1", page: 2).returns(envelope([], page: 2))
    final = resumed.fetch_balance(account: account, cursor: first.next_cursor)
    assert_equal BigDecimal("12.3456789012345678"), final.records.sole[:balance]
    rebound = account_record(descriptor: descriptor.merge("portfolio_id" => "other-portfolio"))
    @client.expects(:portfolio_coins).never
    assert_raises(Provider::AccountData::InvalidResponse) { resumed.fetch_balance(account: rebound, cursor: first.next_cursor) }
  end

  test "duplicate portfolio components invalidate the aggregate" do
    account = account_record(descriptor: exchange_descriptor)
    @client.expects(:portfolio_coins).returns(envelope([ portfolio_coin, portfolio_coin ], page: 1))
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: account) }
  end

  test "older per-asset exchange accounts select their own holding and retain single-asset identity" do
    descriptor = exchange_descriptor.merge("portfolio_account" => false, "asset_id" => "ethereum")
    account = account_record(descriptor: descriptor)
    adapter = build_adapter(external_accounts: [ account.attributes ])
    @client.expects(:portfolio_coins).returns(envelope([ portfolio_coin(count: "2"), portfolio_coin(identifier: "bitcoin", symbol: "BTC", count: "30") ], page: 1))
    page = adapter.fetch_balance(account: account)
    assert_equal BigDecimal("2"), page.records.sole[:balance]
    assert_equal "coinstats_holding_ethereum_2026-09-15", adapter.fetch_holdings(account: account).records.sole[:external_id]
  end

  test "exchange denomination uses explicit price maps and dated FX evidence" do
    account = account_record(descriptor: exchange_descriptor, currency: "EUR")
    rates = ->(from:, to:, date:) do
      assert_equal [ "USD", "EUR", Date.new(2026, 9, 15) ], [ from, to, date ]
      { rate: BigDecimal("0.8"), date: "2026-09-14" }
    end
    adapter = build_adapter(external_accounts: [ account.attributes ], family_currency: "EUR", exchange_rate_resolver: rates)
    coin = portfolio_coin(count: "2").merge("price" => { "EUR" => "5" }, "currentValue" => { "USD" => "12.5" }, "averageBuy" => { "allTime" => { "EUR" => "4" } })
    @client.expects(:portfolio_coins).returns(envelope([ coin ], page: 1))
    page = adapter.fetch_balance(account: account)
    assert_equal BigDecimal("10"), page.records.sole[:balance]
    assert_equal "EUR", page.records.sole[:currency]
    assert_equal "2026-09-14", page.evidence.fetch("valuation").fetch("fx_evidence").sole.fetch("date")
    holding = adapter.fetch_holdings(account: account).records.sole
    assert_equal BigDecimal("5"), holding[:price]
    assert_equal BigDecimal("4"), holding[:metadata][:cost_basis]
  end

  test "an unavailable exchange FX rate cannot relabel a USD scalar as family currency" do
    account = account_record(descriptor: exchange_descriptor, currency: "EUR")
    adapter = build_adapter(external_accounts: [ account.attributes ], family_currency: "EUR")
    @client.expects(:portfolio_coins).returns(envelope([ portfolio_coin ], page: 1))
    assert_raises(Provider::AccountData::InvalidResponse) { adapter.fetch_balance(account: account) }
  end

  test "DeFi total position price is divided by units and unavailable FX retains actual USD" do
    descriptor = defi_descriptor
    account = account_record(descriptor: descriptor, currency: "EUR")
    adapter = build_adapter(external_accounts: [ account.attributes ], family_currency: "EUR")
    @client.expects(:wallet_defi).with(address: "0xABC", blockchain: "ethereum").returns(defi_response)
    page = adapter.fetch_balance(account: account)
    assert_equal BigDecimal("120"), page.records.sole[:balance]
    assert_equal "USD", page.records.sole[:currency]
    holding = adapter.fetch_holdings(account: account).records.sole
    assert_equal BigDecimal("3"), holding[:quantity]
    assert_equal BigDecimal("40"), holding[:price]
    assert_equal "coinstats_holding_defi:ethereum:lido:staking:ethereum:deposit_2026-09-15", holding[:external_id]
    activities = adapter.fetch_activities(account: account)
    assert activities.complete?
    assert_equal false, activities.coverage.fetch("supported")
  end

  test "disappeared DeFi positions do not authorize destructive absence handling" do
    account = account_record(descriptor: defi_descriptor)
    @client.expects(:wallet_defi).returns("protocols" => [])
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: account) }
  end

  test "holdings require current matching valuation and retain legacy Crypto-only behavior" do
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_holdings(account: @account) }
    unsupported = account_record(linked_type: "Investment")
    page = @adapter.fetch_holdings(account: unsupported)
    assert page.complete?
    assert_equal false, page.coverage.fetch("supported")
    assert_empty page.records
  end

  test "wallet cash movements match legacy dates signs identities and transaction metadata" do
    raw = activity(type: "Sent", count: "-0.5", value: "1000.125")
    raw["fee"] = { "count" => "0.001", "totalWorth" => "2", "coin" => { "symbol" => "ETH" } }
    record = @adapter.normalize_activity(raw, account: @account)
    legacy = legacy_processor(raw, @descriptor)
    %i[external_id amount currency date name].each { |key| assert_equal legacy.send(key), record[key] }
    assert_equal "transaction", record.ledger_type
    assert_equal "transfer", record[:activity_type]
    assert_equal "Transfer", record[:metadata][:investment_activity_label]
    assert_equal "insert_only", record[:metadata][:update_policy]
    assert_equal "2", record[:metadata][:extra][:coinstats][:fee_value]
    assert_equal "coinstats_account_legacy-account-1", record[:metadata][:merchant][:external_id]
    assert_nil record[:quantity]
  end

  test "exchange buy sell and swap trades preserve legacy amount signs and selected leg" do
    descriptor = exchange_descriptor
    account = account_record(descriptor: descriptor)
    %w[buy sell swap].each do |type|
      count = type == "buy" ? "0.5" : "-0.5"
      raw = activity(type: type, count: count, value: "1000")
      record = @adapter.normalize_activity(raw, account: account)
      legacy = legacy_processor(raw, descriptor)
      %i[external_id currency date name].each { |key| assert_equal legacy.send(key), record[key] }
      assert_equal legacy.send(:trade_quantity), record[:quantity]
      assert_equal legacy.send(:trade_price), record[:price]
      assert_equal legacy.send(:trade_amount), record[:amount]
      assert_equal legacy.send(:trade_activity_label), record[:metadata][:investment_activity_label]
      assert_equal "trade", record.ledger_type
      assert_nil record[:metadata][:fee]
    end
  end

  test "portfolio swap chooses the negative crypto leg ahead of positive fiat and crypto" do
    raw = activity(type: "Swap", count: "1", value: "200")
    raw["transactions"].first["items"] = [
      { "count" => "100", "totalWorth" => "100", "coin" => { "identifier" => "FiatCoinUSD", "symbol" => "USD" } },
      { "count" => "1", "totalWorth" => "200", "coin" => { "id" => "ethereum", "symbol" => "ETH" } },
      { "count" => "-0.01", "totalWorth" => "200", "coin" => { "id" => "bitcoin", "symbol" => "BTC" } }
    ]
    record = @adapter.normalize_activity(raw, account: account_record(descriptor: exchange_descriptor))
    assert_equal "sell", record[:activity_type]
    assert_equal BigDecimal("-200"), record[:amount]
    assert_equal BigDecimal("-0.01"), record[:quantity]
    assert_equal "CRYPTO:BTC", record[:security][:ticker]
  end

  test "wallet request is scoped independently and irrelevant coins cannot leak into another account" do
    raw = activity
    other = activity(id: "other", coin_id: "bitcoin", symbol: "BTC")
    @client.expects(:wallet_transactions).with(address: "0xABC", blockchain: "ethereum", currency: "USD", page: 1, from: nil, to: @observed_at.iso8601(9))
      .returns(envelope([ raw, other ], page: 1))
    page = @adapter.fetch_activities(account: @account)
    assert page.complete?
    assert_equal [ "coinstats_tx-1" ], page.records.map { |record| record[:external_id] }
    assert_equal false, page.coverage.fetch("pending_absence_authoritative")
    assert_equal 2, page.evidence.fetch("response").fetch("result").size
  end

  test "history pagination fixes scope currency window and resumes without re-fetching earlier pages" do
    rows = 100.times.map { |index| activity(id: "tx-#{index}") }
    @client.expects(:wallet_transactions).with(has_entries(page: 1, from: "2025-01-01T00:00:00Z")).returns(envelope(rows, page: 1))
    first = @adapter.fetch_activities(account: @account, window: { "start" => "2025-01-01T00:00:00Z", "explicit_start" => true })
    assert_not first.complete?
    assert_equal 100, first.records.size
    adapter = build_adapter
    @client.expects(:wallet_transactions).with(has_entries(page: 2, from: "2025-01-01T00:00:00Z")).returns(envelope([ activity(id: "next") ], page: 2))
    last = adapter.fetch_activities(account: @account, cursor: first.next_cursor)
    assert last.complete?
    assert_equal "coinstats_next", last.records.sole[:external_id]
    assert_equal first.coverage, last.coverage
    assert_raises(Provider::AccountData::InvalidResponse) { adapter.fetch_activities(account: account_record(currency: "EUR"), cursor: first.next_cursor) }
  end

  test "empty unsynced history and invalid records cannot advance coverage" do
    @client.expects(:wallet_transactions).returns(envelope([], page: 1))
    page = @adapter.fetch_activities(account: @account)
    assert_not page.complete?
    assert_equal "empty_history_requires_readiness", page.warnings.sole.fetch("code")
    @client.expects(:wallet_transactions).returns(envelope([ activity, activity ], page: 1))
    repeated = @adapter.fetch_activities(account: @account)
    assert_not repeated.complete?
    assert_equal 1, repeated.records.size
    assert_nil repeated.next_cursor
  end

  test "unsupported exchange fallback does not silently change endpoints after failure" do
    account = account_record(descriptor: exchange_descriptor)
    @client.expects(:exchange_transactions).raises(Provider::Coinstats::Error, "unavailable")
    @client.expects(:portfolio_transactions).never
    assert_raises(Provider::Coinstats::Error) { @adapter.fetch_activities(account: account) }
  end

  test "request budget leaves a durable continuation instead of starting an unbounded history loop" do
    continuation = nil
    20.times do |page_index|
      rows = 100.times.map { |row_index| activity(id: "tx-#{page_index}-#{row_index}") }
      @client.expects(:wallet_transactions).with(has_entries(page: page_index + 1)).once.returns(envelope(rows, page: page_index + 1))
      page = @adapter.fetch_activities(account: @account, cursor: continuation)
      continuation = page.progress_cursor
      assert continuation.present?
    end
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_activities(account: @account, cursor: continuation) }
    resumed = build_adapter
    @client.expects(:wallet_transactions).with(has_entries(page: 21)).once.returns(envelope([], page: 21))
    assert resumed.fetch_activities(account: @account, cursor: continuation).complete?
  end

  test "fallback identity matches legacy binary spelling while native amounts stay exact" do
    raw = activity(value: BigDecimal("123456789.123456789123456789"), count: BigDecimal("0.123456789123456789"))
    raw.delete("hash")
    raw["transactions"].first["items"].first.delete("id")
    legacy_raw = Marshal.load(Marshal.dump(raw))
    legacy_raw["coinData"]["count"] = raw["coinData"]["count"].to_f
    legacy_raw["transactions"].first["items"].first["count"] = raw["coinData"]["count"].to_f
    record = @adapter.normalize_activity(raw, account: @account)
    assert_equal legacy_processor(legacy_raw, @descriptor).send(:external_id), record[:external_id]
    assert_equal BigDecimal("-123456789.123456789123456789"), record[:amount]
    raw["coinData"]["currentValue"] = "1"
    assert_equal record[:external_id], @adapter.normalize_activity(raw, account: @account)[:external_id]
  end

  test "binary floats are rejected in native money but explicitly supported for archived projections" do
    raw = activity(value: 12.5, count: 0.5)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(raw, account: @account) }
    record = @adapter.normalize_legacy_activity(raw, account: @account)
    assert_equal BigDecimal("-12.5"), record[:amount]
    assert_equal "coinstats_tx-1", record[:external_id]
  end

  private
    def build_adapter(**attributes)
      Provider::AccountData::Coinstats.new(**{ client: @client, external_accounts: [ @account.attributes ], exchange_rate_resolver: @rates,
        timezone: "UTC", family_currency: "USD", observed_at: @observed_at }.merge(attributes))
    end

    def descriptor(**attributes)
      { "version" => 1, "source" => "wallet", "asset_id" => "ethereum", "wallet_address" => "0xABC", "address" => "0xABC",
        "blockchain" => "ethereum", "portfolio_account" => false, "fiat" => false, "symbol" => "ETH", "asset_name" => "Ethereum",
        "legacy_account_uuid" => "legacy-account-1", "institution_logo" => "https://example.test/eth.png" }.merge(attributes.stringify_keys)
    end

    def exchange_descriptor
      descriptor(source: "exchange", asset_id: "portfolio:portfolio-1", wallet_address: "portfolio-1", portfolio_id: "portfolio-1", portfolio_account: true)
        .except("address", "blockchain")
    end

    def defi_descriptor
      descriptor(source: "defi", asset_id: "defi:ethereum:lido:staking:ethereum:deposit", protocol_id: "lido", asset_title: "Deposit", investment_type: "Staking")
    end

    def account_record(descriptor: @descriptor, currency: "USD", linked_type: "Crypto")
      identity = JSON.generate([ [ "account_id", descriptor.fetch("asset_id") ], [ "wallet_address", descriptor["wallet_address"] ] ])
      Ingestion::Record.account(external_id: identity, name: "Ethereum wallet", currency: currency,
        metadata: { linked_account_type: linked_type }, sensitive_details: { source_descriptor: descriptor })
    end

    def wallet_coin
      { "coinId" => "ethereum", "symbol" => "ETH", "name" => "Ethereum", "amount" => "1", "price" => "2000" }
    end

    def wallet_response(*coins)
      [ { "address" => "0xABC", "connectionId" => "ethereum", "balances" => coins } ]
    end

    def portfolio_coin(identifier: "ethereum", symbol: "ETH", count: "1", is_fiat: false)
      { "coin" => { "identifier" => identifier, "symbol" => symbol, "name" => symbol, "isFiat" => is_fiat }, "count" => count, "price" => { "USD" => "1" } }
    end

    def defi_response
      { "protocols" => [ { "id" => "lido", "name" => "Lido", "investments" => [ { "name" => "Staking", "assets" => [
        { "coinId" => "ethereum", "symbol" => "ETH", "title" => "Deposit", "amount" => "3", "price" => { "USD" => "120" } }
      ] } ] } ] }
    end

    def envelope(rows, page:)
      { "result" => rows, "meta" => { "page" => page, "limit" => 100 } }
    end

    def activity(id: "tx-1", type: "Received", count: "0.5", value: "1000", coin_id: "ethereum", symbol: "ETH")
      { "type" => type, "date" => "2026-09-14T23:59:00Z", "hash" => { "id" => id },
        "coinData" => { "identifier" => coin_id, "symbol" => symbol, "count" => count, "currentValue" => value },
        "transactions" => [ { "action" => type, "items" => [ { "id" => id, "count" => count, "totalWorth" => value, "coin" => { "id" => coin_id, "symbol" => symbol } } ] } ] }
    end

    def legacy_processor(raw, descriptor)
      payload = descriptor.merge("source" => descriptor.fetch("source"), "symbol" => descriptor.fetch("symbol"))
      legacy = CoinstatsAccount.new(name: "Ethereum wallet", currency: "USD", account_id: descriptor.fetch("asset_id"), raw_payload: payload)
      legacy.stubs(:current_account).returns(OpenStruct.new(currency: "USD", family: OpenStruct.new(timezone: "UTC")))
      CoinstatsEntry::Processor.new(raw, coinstats_account: legacy)
    end
end
