require "test_helper"

class Provider::AccountData::BinanceTest < ActiveSupport::TestCase
  setup do
    @client = mock("Binance transport")
    @observed_at = Time.utc(2026, 2, 15, 2)
    @adapter = adapter
    @account = account
  end

  test "factory uses explicit credentials family currency and conversion dependency and remains gated" do
    resolver = mock("FX resolver")
    Provider::Binance.expects(:new).with(api_key: "key", api_secret: "secret").returns(@client)
    built = Provider::AccountData::Binance.build(credentials: { api_key: "key", api_secret: "secret" }, settings: {}, context: {
      family_currency: "USD", timezone: "America/Los_Angeles", observed_at: @observed_at, exchange_rate_resolver: resolver,
      binance_history_seed: { "checkpoint" => nil, "seed" => {} }
    })

    assert_equal %w[holdings activities], built.capabilities
    assert_equal %i[external_accounts exchange_rate_resolver binance_history_seed], Provider::AccountData::Binance.context_sources
    refute Provider::AccountData::Binance.native_ready?
    refute_includes built.inspect, "secret"
  end

  test "spot margin and futures preserve distinct exact quantity conventions" do
    spot = @adapter.normalize_assets("spot", [ { asset: "BTC", free: "0.000000000000000148", locked: "0.25" } ]).first
    margin = @adapter.normalize_assets("margin", [ { asset: "ETH", free: "10", locked: "1", netAsset: "-2.123456789012345678" } ]).first
    futures = @adapter.normalize_assets("futures", [ { asset: "USDT", walletBalance: "100", unrealizedProfit: "-2.12", availableBalance: "75" } ]).first

    assert_equal "0.250000000000000148", spot[:total]
    assert_equal "-2.123456789012345678", margin[:total]
    assert_equal "10.0", margin[:free]
    assert_equal "97.88", futures[:total]
    assert_equal "25.0", futures[:locked]
  end

  test "inventory reads five sources into one stable account without splitting the portfolio" do
    Provider::AccountData::Binance::SOURCES.each do |source|
      @client.expects(:get_portfolio_page).with(source, page: 1).returns(page([]))
    end

    pages = read_inventory(@adapter)

    assert_equal 5, pages.size
    assert_equal [ "combined" ], pages.flat_map(&:records).map { |row| row[:external_id] }.uniq
    assert pages.last.complete?
    assert pages.first.records.first[:balance].nil?
    assert_equal false, pages.first.records.first[:metadata][:balance_provided]
  end

  test "Earn pages retain their captured prefix across adapter reconstruction and merge locked and flexible units" do
    @client.expects(:get_portfolio_page).with("spot", page: 1).returns(page([]))
    @client.expects(:get_portfolio_page).with("margin", page: 1).returns(page([]))
    @client.expects(:get_portfolio_page).with("earn_flexible", page: 1).returns(page([ { asset: "USDT", totalAmount: "2" } ], next_cursor: "2"))
    first = @adapter.list_accounts
    second = @adapter.list_accounts(cursor: first.next_cursor)
    prefix = @adapter.list_accounts(cursor: second.next_cursor)
    restored = adapter(external_accounts: [ { external_id: "combined", metadata: prefix.records.first[:metadata] } ])
    @client.expects(:get_portfolio_page).with("earn_flexible", page: 2).returns(page([ { asset: "USDT", totalAmount: "3" } ]))
    @client.expects(:get_portfolio_page).with("earn_locked", page: 1).returns(page([ { asset: "USDT", amount: "7" } ]))
    @client.expects(:get_portfolio_page).with("futures", page: 1).returns(page([]))

    tail = read_inventory(restored, cursor: prefix.next_cursor)
    result = restored.fetch_holdings(account: tail.last.records.first).records.first

    assert_equal BigDecimal("12"), result[:quantity]
    assert_equal "binance_USDT_earn_2026-02-14", result[:external_id]
    assert tail.last.complete?
  end

  test "a failed source preserves only its previous positions and cannot claim complete inventory" do
    old = source_snapshots
    old["margin"] = { assets: [ asset("USDT", "12") ], available: true, observed_at: (@observed_at - 1.day).iso8601(9) }
    restored = adapter(external_accounts: [ { external_id: "combined", metadata: { portfolio_sources: old } } ])
    @client.expects(:get_portfolio_page).with("spot", page: 1).returns(page([]))
    @client.expects(:get_portfolio_page).with("margin", page: 1).raises(Provider::Binance::AuthenticationError.new("permission"))
    %w[earn_flexible earn_locked futures].each { |source| @client.expects(:get_portfolio_page).with(source, page: 1).returns(page([])) }

    pages = read_inventory(restored)
    result = restored.fetch_holdings(account: pages.last.records.first)

    refute pages.last.complete?
    assert_equal "margin", pages[1].warnings.first["source"]
    assert_equal BigDecimal("12"), result.records.first[:quantity]
    assert_equal [ "margin" ], result.coverage["unavailable_sources"]
  end

  test "an unavailable source without prior evidence cannot turn into a partial monetary total" do
    sources = source_snapshots
    sources["margin"] = { available: false }
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_balance(account: account(sources: sources)) }
  end

  test "rate limiting stops later source and valuation requests in the same sync" do
    @client.expects(:get_portfolio_page).with("spot", page: 1).raises(Provider::Binance::RateLimitError.new("wait"))
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.list_accounts }
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_balance(account: @account) }
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_activities(account: @account) }
  end

  test "balance pages never apply a partial sum and retain exact fiat conversion evidence" do
    sources = source_snapshots
    sources["spot"][:assets] = [ asset("BTC", "0.5"), asset("USDT", "10") ]
    resolver = mock("FX resolver")
    resolver.expects(:call).with(from: "USD", to: "EUR", date: Date.new(2026, 2, 14))
      .returns({ rate: BigDecimal("0.92"), date: "2026-02-13" })
    native = adapter(currency: "EUR", exchange_rate_resolver: resolver)
    @client.expects(:get_price_page).with("BTCUSDT", date: nil).returns(page([ { price: "100" } ]))

    first = native.fetch_balance(account: account(sources: sources))
    last = native.fetch_balance(account: account(sources: sources), cursor: first.progress_cursor)

    refute first.complete?
    assert_nil first.records.first[:balance]
    assert_equal false, first.records.first[:metadata][:balance_provided]
    assert last.complete?
    assert_equal BigDecimal("55.2"), last.records.first[:balance]
    assert_equal "EUR", last.records.first[:currency]
    assert_equal true, last.evidence["fx"]["stale_rate"]
    assert_equal BigDecimal("0.92"), last.evidence["fx"]["rate"]
  end

  test "missing spot valuation and missing family FX fail instead of inventing zero or relabelled USD" do
    sources = source_snapshots
    sources["spot"][:assets] = [ asset("BTC", "1") ]
    @client.expects(:get_price_page).with("BTCUSDT", date: nil).raises(Provider::Binance::ApiError.new("unavailable"))
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_balance(account: account(sources: sources)) }

    sources["spot"][:assets] = [ asset("USDT", "1") ]
    assert_raises(Provider::AccountData::IncompletePage) { adapter(currency: "EUR").fetch_balance(account: account(sources: sources)) }
  end

  test "position IDs dates signs quote fallbacks and security MIC match legacy semantics" do
    sources = source_snapshots
    sources["margin"][:assets] = [ asset("ETH", "-0.000000000000000148") ]
    @client.expects(:get_price_page).with("ETHUSDT", date: nil).raises(Provider::Binance::InvalidSymbolError.new("absent"))
    @client.expects(:get_price_page).with("ETHBUSD", date: nil).returns(page([ { price: "3000.12345678" } ]))

    holding = @adapter.fetch_holdings(account: account(sources: sources)).records.first

    assert_equal "binance_ETH_margin_2026-02-14", holding[:external_id]
    assert_equal BigDecimal("-0.000000000000000148"), holding[:quantity]
    assert_equal BigDecimal("3000.12345678"), holding[:price]
    assert_equal "CRYPTO:ETH", holding[:security][:ticker]
    assert_equal "XBNC", holding[:security][:fallback_exchange_operating_mic]
    assert_equal false, holding[:metadata][:delete_future_holdings]
  end

  test "spot and futures trades preserve legacy signs exact commission and USD units" do
    buy, = @adapter.normalize_trade(trade, pair: "BTCUSDT", market: "spot")
    sell, = @adapter.normalize_trade(trade(buyer: false), pair: "BTCUSDT", market: "futures")

    assert_equal "binance_spot_BTCUSDT_101", buy[:external_id]
    assert_equal BigDecimal("0.25"), buy[:quantity]
    assert_equal BigDecimal("-12500.12"), buy[:amount]
    assert_equal BigDecimal("-0.25"), sell[:quantity]
    assert_equal BigDecimal("12500.12"), sell[:amount]
    assert_equal "USD", sell[:currency]
    assert_equal BigDecimal("0.123456789012345678"), buy[:metadata][:fee]
    assert_equal "insert_only", buy[:metadata][:update_policy]
  end

  test "crypto quotes and third-asset commissions use historical prices with exact conversion" do
    @client.expects(:get_price_page).with("BTCUSDT", date: Date.new(2026, 2, 14)).returns(page([ { price: "50000" } ]))
    @client.expects(:get_price_page).with("BNBUSDT", date: Date.new(2026, 2, 14)).returns(page([ { price: "300" } ]))
    raw = trade.merge(price: "0.05", quoteQty: "0.0125", commission: "0.01", commissionAsset: "BNB")

    record, evidence = @adapter.normalize_trade(raw, pair: "ETHBTC", market: "spot")

    assert_equal BigDecimal("2500"), record[:price]
    assert_equal BigDecimal("-625"), record[:amount]
    assert_equal BigDecimal("3"), record[:metadata][:fee]
    assert evidence.first.key?("commission")
  end

  test "P2P keeps both atomic legs native fiat net quantity and crypto fee conversion" do
    funding, buy = @adapter.normalize_p2p(p2p)
    sell, receipt = @adapter.normalize_p2p(p2p.merge(tradeType: "SELL"))

    assert_equal "binance_p2p_order_1_funding", funding[:external_id]
    assert_equal BigDecimal("-31500"), funding[:amount]
    assert_equal "TZS", buy[:currency]
    assert_equal BigDecimal("31500"), buy[:amount]
    assert_equal BigDecimal("11.41"), buy[:quantity]
    assert_equal BigDecimal("164.78"), buy[:metadata][:fee]
    assert_equal BigDecimal("-11.41"), sell[:quantity]
    assert_equal BigDecimal("-31500"), sell[:amount]
    assert_equal BigDecimal("31500"), receipt[:amount]
    assert_equal "", funding[:metadata][:investment_activity_label]
    assert_equal buy[:metadata][:atomic_group], funding[:metadata][:atomic_group]
    assert_equal [ "Trade", "Transaction" ], buy[:metadata][:atomic_group][:members].map { |member| member[:financial_type] }
  end

  test "P2P pagination emits complete groups and finishes both sides even without spot assets" do
    @client.expects(:get_p2p_page).with { |args| args[:trade_type] == "BUY" && args[:page] == 1 }.returns(page([ p2p ], next_cursor: "2"))
    first = @adapter.fetch_activities(account: @account)
    @client.expects(:get_p2p_page).with { |args| args[:trade_type] == "BUY" && args[:page] == 2 }.returns(page([]))
    second = @adapter.fetch_activities(account: @account, cursor: first.next_cursor)
    @client.expects(:get_p2p_page).with { |args| args[:trade_type] == "SELL" }.returns(page([]))
    last = @adapter.fetch_activities(account: @account, cursor: second.next_cursor)

    assert_equal 2, first.records.size
    assert_equal first.records.map { |record| record[:external_id] }.sort,
      first.records.first[:metadata][:atomic_group][:members].map { |member| member[:external_id] }.sort
    refute second.complete?
    assert last.complete?
    assert last.checkpoint_cursor
  end

  test "sold-out cached pairs survive discovery and incremental requests use fromId without timestamps" do
    native = adapter(cached_history: { ids: { spot: { "BTCUSDT" => 100 }, futures: {} } })
    cursor = enter_trade_history(native)
    @client.expects(:get_trades_page).with("BTCUSDT", market: "spot", from_id: 101).returns(page([ trade ]))

    result = native.fetch_activities(account: @account, cursor: cursor)

    assert_equal "binance_spot_BTCUSDT_101", result.records.first[:external_id]
    assert result.progress_cursor
  end

  test "a full initial window switches to fromId and retains trades at the same millisecond" do
    native = adapter(cached_history: { ids: { spot: {}, futures: { "BTCUSDT" => 1 } } })
    cursor = enter_trade_history(native)
    rows = (1..1000).map { |id| trade(id: id) }
    @client.expects(:get_trades_page).with { |symbol, args| symbol == "BTCUSDT" && args[:market] == "spot" && args.key?(:start_time) && !args.key?(:from_id) }.returns(page(rows))
    first = native.fetch_activities(account: @account, cursor: cursor)
    @client.expects(:get_trades_page).with("BTCUSDT", market: "spot", from_id: 1001).returns(page([ trade(id: 1001) ]))

    second = native.fetch_activities(account: @account, cursor: first.next_cursor)

    assert_equal 1000, first.records.size
    assert_equal "binance_spot_BTCUSDT_1001", second.records.first[:external_id]
  end

  test "futures initial history clamps to six months and uses seven day windows" do
    native = adapter(cached_history: { ids: { spot: { "BTCUSDT" => 100 }, futures: {} }, p2p_after: @observed_at.to_i * 1000 })
    cursor = enter_trade_history(native, window: { explicit_start: true, start: "2020-01-01T00:00:00Z" })
    @client.expects(:get_trades_page).with("BTCUSDT", market: "spot", from_id: 101).returns(page([]))
    first = native.fetch_activities(account: @account, cursor: cursor)
    end_ms = @observed_at.to_i * 1000
    @client.expects(:get_trades_page).with("BTCUSDT", market: "futures", start_time: end_ms - 15_552_000_000,
      end_time: end_ms - 15_552_000_000 + 604_800_000 - 1).returns(page([]))

    refute native.fetch_activities(account: @account, cursor: first.next_cursor).complete?
  end

  test "nonadvancing IDs malformed rows missing valuations and legacy account topologies fail visibly" do
    native = adapter(cached_history: { ids: { spot: { "BTCUSDT" => 100 }, futures: {} } })
    cursor = enter_trade_history(native)
    @client.expects(:get_trades_page).returns(page([ trade(id: 100) ]))
    assert_raises(Provider::AccountData::IncompletePage) { native.fetch_activities(account: @account, cursor: cursor) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_trade(trade.merge(qty: 0.25), pair: "BTCUSDT", market: "spot") }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_p2p(p2p.merge(takerAmount: "NaN")) }
    legacy = Ingestion::Record.account(external_id: "spot", name: "Legacy spot", currency: "USD")
    assert_raises(Provider::AccountData::UnsupportedCapability) { @adapter.fetch_holdings(account: legacy) }
  end

  test "a changed portfolio discards an old partial balance sum before restarting valuation" do
    sources = source_snapshots
    sources["spot"][:assets] = [ asset("USDT", "10"), asset("USDC", "20") ]
    first = @adapter.fetch_balance(account: account(sources: sources))
    sources["spot"][:assets] = [ asset("USDT", "3") ]

    refreshed = @adapter.fetch_balance(account: account(sources: sources), cursor: first.progress_cursor)

    assert_equal BigDecimal("3"), refreshed.records.first[:balance]
  end

  test "the same asset in different sources remains distinct evidence for shared holding reconciliation" do
    sources = source_snapshots
    sources["spot"][:assets] = [ asset("USDT", "10") ]
    sources["earn_locked"][:assets] = [ asset("USDT", "20") ]
    first = @adapter.fetch_holdings(account: account(sources: sources))
    second = @adapter.fetch_holdings(account: account(sources: sources), cursor: first.next_cursor)

    assert_equal "binance_USDT_earn_2026-02-14", first.records.first[:external_id]
    assert_equal "binance_USDT_spot_2026-02-14", second.records.first[:external_id]
    assert_equal BigDecimal("20"), first.records.first[:quantity]
    assert_equal BigDecimal("10"), second.records.first[:quantity]
    assert_equal "requires_source_snapshot_reconciliation", second.coverage["absence_policy"]
  end

  private
    def adapter(**options)
      Provider::AccountData::Binance.new(**{ client: @client, currency: "USD", timezone: "America/Los_Angeles", observed_at: @observed_at }.merge(options))
    end

    def source_snapshots
      Provider::AccountData::Binance::SOURCES.to_h { |source| [ source, { assets: [], available: true, observed_at: @observed_at.iso8601(9) } ] }
    end

    def account(sources: source_snapshots)
      Ingestion::Record.account(external_id: "combined", name: "Binance", currency: "USD",
        metadata: { portfolio_sources: sources, portfolio_observed_at: @observed_at.iso8601(9), linked_account_type: "Crypto" })
    end

    def asset(symbol, total)
      { symbol: symbol, total: total, free: total, locked: "0" }
    end

    def page(items, next_cursor: nil)
      { items: items, next_cursor: next_cursor }
    end

    def read_inventory(native, cursor: nil)
      pages = []
      loop do
        result = native.list_accounts(cursor: cursor)
        pages << result
        break unless result.next_cursor
        cursor = result.next_cursor
      end
      pages
    end

    def enter_trade_history(native, window: nil)
      @client.stubs(:get_p2p_page).returns(page([]))
      cursor = nil
      loop do
        result = native.fetch_activities(account: @account, cursor: cursor, window: window)
        cursor = result.next_cursor
        state = JSON.parse(Base64.urlsafe_decode64(cursor))
        return cursor if state["phase"] == "trades"
      end
    end

    def trade(id: 101, buyer: true)
      { id: id, time: Time.utc(2026, 2, 14, 12).to_i * 1000, qty: "0.25", price: "50000.48", quoteQty: "12500.12",
        commission: "0.123456789012345678", commissionAsset: "USDT", isBuyer: buyer }
    end

    def p2p
      { orderNumber: "order_1", createTime: Time.utc(2026, 2, 14, 12).to_i * 1000, tradeType: "BUY", asset: "USDT",
        fiat: "TZS", totalPrice: "31500", unitPrice: "2746.29", amount: "11.47", takerAmount: "11.41", takerCommission: "0.06" }
    end
end
