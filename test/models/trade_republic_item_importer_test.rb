require "test_helper"

class TradeRepublicItemImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = trade_republic_items(:configured_item)
    @item.trade_republic_accounts.destroy_all
  end

  test "import creates trade_republic_account with exact decimal balances" do
    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE9999", "currency" => "EUR" },
      "cash" => { "amount" => "250.55", "currency" => "EUR" },
      "positions" => [
        { "isin" => "US0378331005", "name" => "Apple Inc.", "quantity" => "13.439945", "price" => "183.94", "average_cost" => "150.10" }
      ],
      "events" => [],
      "newest_event_id" => "evt_2",
      "warnings" => []
    ))

    result = TradeRepublicItem::Importer.new(@item, provider: provider).import

    assert_equal true, result[:success]
    assert_equal 0, result[:detail_backfill_count]

    account = @item.trade_republic_accounts.find_by(trade_republic_account_id: "DE9999")
    assert_not_nil account

    expected_portfolio = BigDecimal("13.439945") * BigDecimal("183.94")
    assert_equal expected_portfolio.round(4), account.current_balance
    assert_equal BigDecimal("0"), account.cash_balance
    cash_account = @item.trade_republic_accounts.find_by(kind: "cash")
    assert_equal BigDecimal("250.55"), cash_account.current_balance
    assert_equal BigDecimal("250.55"), cash_account.cash_balance
    assert_equal 1, account.raw_positions_payload.size
  end

  test "repeated sync updates the same account row and stays idempotent" do
    provider_payload = lambda {
      client_result(
        "status" => "ok",
        "session_txt" => "# refreshed cookies",
        "account" => { "brokerage_account_id" => "DE1111", "currency" => "EUR" },
        "cash" => { "amount" => "100.00", "currency" => "EUR" },
        "positions" => [],
        "events" => [ { "id" => "evt_9", "timestamp" => "2026-08-01T12:00:00.000Z", "category" => "orderExecution" } ],
        "newest_event_id" => "evt_9",
        "warnings" => []
      )
    }

    provider = mock("trade_republic_provider")
    provider.expects(:sync).twice.returns(provider_payload.call)

    TradeRepublicItem::Importer.new(@item, provider: provider).import
    state_after_first_sync = @item.trade_republic_accounts.order(:kind).map do |account|
      [ account.kind, account.trade_republic_account_id, account.current_balance.to_s, account.cash_balance.to_s, account.raw_positions_payload, account.raw_timeline_payload ]
    end
    TradeRepublicItem::Importer.new(@item, provider: provider).import
    state_after_second_sync = @item.reload.trade_republic_accounts.order(:kind).map do |account|
      [ account.kind, account.trade_republic_account_id, account.current_balance.to_s, account.cash_balance.to_s, account.raw_positions_payload, account.raw_timeline_payload ]
    end

    assert_equal 1, @item.trade_republic_accounts.where(kind: "portfolio").count
    assert_equal 1, @item.trade_republic_accounts.where(kind: "cash").count
    assert_equal "evt_9", @item.reload.newest_event_id
    assert_equal state_after_first_sync, state_after_second_sync
  end

  test "preserves and recovers timeline events when the provider returns an empty delta" do
    @item.trade_republic_accounts.destroy_all
    account = @item.trade_republic_accounts.create!(
      name: "Existing",
      trade_republic_account_id: "DE4444",
      currency: "EUR",
      raw_timeline_payload: [ { "id" => "evt_old", "category" => "PAYMENT_RECEIVED" } ]
    )
    @item.update!(newest_event_id: "evt_old")

    provider = mock("trade_republic_provider")
    provider.expects(:sync).with { |args| args[:known_newest_event_id] == "evt_old" }.returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE4444", "currency" => "EUR" },
      "cash" => { "amount" => "1", "currency" => "EUR" },
      "positions" => [],
      "events" => [],
      "newest_event_id" => "evt_old",
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import
    assert_equal [ "evt_old" ], account.reload.raw_timeline_payload.map { |event| event["id"] }

    @item.update!(newest_event_id: "evt_missing")
    provider.expects(:sync).with { |args| args[:known_newest_event_id] == "evt_missing" }.returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE4444", "currency" => "EUR" },
      "cash" => { "amount" => "1", "currency" => "EUR" },
      "positions" => [],
      "events" => [ { "id" => "evt_recovered", "category" => "PAYMENT_RECEIVED" } ],
      "newest_event_id" => "evt_recovered",
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import
    assert_equal %w[evt_old evt_recovered], account.reload.raw_timeline_payload.map { |event| event["id"] }
  end

  test "session expiry marks item requires_update and preserves stored payloads" do
    @item.trade_republic_accounts.create!(
      name: "Existing",
      trade_republic_account_id: "DE2222",
      currency: "EUR",
      current_balance: BigDecimal("42.00"),
      cash_balance: BigDecimal("7.00"),
      raw_positions_payload: [ { "isin" => "XX", "quantity" => "1", "price" => "1" } ]
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "session_expired"
    ))

    error = assert_raises(Provider::TradeRepublicClient::AuthenticationRequired) do
      TradeRepublicItem::Importer.new(@item, provider: provider).import
    end

    assert_match(/expired/i, error.message)
    assert @item.reload.requires_update?

    account = @item.trade_republic_accounts.find_by(trade_republic_account_id: "DE2222")
    assert_not_nil account.raw_positions_payload.first
    assert_equal BigDecimal("42.00"), account.current_balance
  end

  test "provider failure propagates without touching existing payloads" do
    @item.trade_republic_accounts.create!(
      name: "Existing",
      trade_republic_account_id: "DE3333",
      currency: "EUR",
      current_balance: BigDecimal("99.00"),
      cash_balance: BigDecimal("5.00"),
      raw_positions_payload: [ { "isin" => "KEEP", "quantity" => "2", "price" => "3" } ]
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).raises(Provider::TradeRepublicClient::ProviderUnavailable, "network down")

    assert_raises(Provider::TradeRepublicClient::ProviderUnavailable) do
      TradeRepublicItem::Importer.new(@item, provider: provider).import
    end

    account = @item.trade_republic_accounts.find_by(trade_republic_account_id: "DE3333")
    assert_equal [ { "isin" => "KEEP", "quantity" => "2", "price" => "3" } ], account.reload.raw_positions_payload
    assert_equal BigDecimal("99.00"), account.current_balance
  end

  test "ignores malformed timeline elements without breaking quality summaries" do
    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE-MALFORMED", "currency" => "EUR" },
      "cash" => { "amount" => "1", "currency" => "EUR" },
      "positions" => [],
      "events" => [ "unexpected-event", { "id" => "known", "category" => "PAYMENT_RECEIVED" } ],
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    assert_equal 1, @item.reload.data_quality_summary[:events]
    assert_equal 0, @item.data_quality_summary[:unknown_events]
  end

  test "unpriced positions preserve the last known portfolio balance" do
    portfolio = @item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Existing portfolio",
      currency: "EUR",
      trade_republic_account_id: "DE5555",
      current_balance: BigDecimal("1234.56"),
      raw_positions_payload: [ { "isin" => "KEEP", "quantity" => "2", "price" => "617.28" } ]
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE5555", "currency" => "EUR" },
      "cash" => { "amount" => "0", "currency" => "EUR" },
      "positions" => [ { "isin" => "KEEP", "quantity" => "2" } ],
      "events" => [],
      "warnings" => [ "price unavailable for KEEP" ]
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    assert_equal BigDecimal("1234.56"), portfolio.reload.current_balance
    assert_equal false, portfolio.holdings_snapshot_complete?
    assert_equal "617.28", portfolio.raw_positions_payload.first["price"]
  end

  test "cash success with timeline failure updates cash but preserves timeline and cursor" do
    portfolio = @item.trade_republic_accounts.create!(
      kind: "portfolio",
      trade_republic_account_id: "DE-DOMAIN",
      currency: "EUR",
      raw_timeline_payload: [ { "id" => "old-event" } ]
    )
    cash = @item.trade_republic_accounts.create!(
      kind: "cash",
      trade_republic_account_id: "cash:DE-DOMAIN",
      currency: "EUR",
      current_balance: BigDecimal("10.00"),
      cash_balance: BigDecimal("10.00"),
      raw_timeline_payload: [ { "id" => "old-event" } ]
    )
    @item.update!(newest_event_id: "old-event")

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "partial",
      "domain_statuses" => { "account_metadata" => "success", "cash" => "success", "portfolio" => "success", "timeline" => "failed", "instrument_metadata" => "success" },
      "account" => { "brokerage_account_id" => "DE-DOMAIN", "currency" => "EUR" },
      "cash" => { "amount" => "99.99", "currency" => "EUR" },
      "positions" => [],
      "events" => [ { "id" => "new-event" } ],
      "newest_event_id" => "new-event",
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    assert_equal BigDecimal("99.99"), cash.reload.current_balance
    assert_equal [ "old-event" ], portfolio.reload.raw_timeline_payload.map { |event| event["id"] }
    assert_equal "old-event", @item.reload.newest_event_id
  end

  test "portfolio success with cash failure updates holdings snapshot but preserves cash" do
    portfolio = @item.trade_republic_accounts.create!(
      kind: "portfolio",
      trade_republic_account_id: "DE-PORTFOLIO",
      currency: "EUR",
      current_balance: BigDecimal("10.00"),
      raw_positions_payload: [ { "isin" => "OLD", "quantity" => "1", "price" => "10" } ]
    )
    cash = @item.trade_republic_accounts.create!(
      kind: "cash",
      trade_republic_account_id: "cash:DE-PORTFOLIO",
      currency: "EUR",
      current_balance: BigDecimal("42.00"),
      cash_balance: BigDecimal("42.00")
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "partial",
      "domain_statuses" => { "account_metadata" => "success", "cash" => "failed", "portfolio" => "success", "timeline" => "success", "instrument_metadata" => "success" },
      "account" => { "brokerage_account_id" => "DE-PORTFOLIO", "currency" => "EUR" },
      "positions" => [ { "isin" => "NEW", "quantity" => "2", "price" => "20" } ],
      "events" => [],
      "newest_event_id" => "event-1",
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    assert_equal [ "NEW" ], portfolio.reload.raw_positions_payload.map { |position| position["isin"] }
    assert_equal BigDecimal("42.00"), cash.reload.current_balance
  end

  test "malformed domain status never treats missing cash as an empty successful snapshot" do
    cash = @item.trade_republic_accounts.create!(
      kind: "cash",
      trade_republic_account_id: "cash:DE-MALFORMED",
      currency: "EUR",
      current_balance: BigDecimal("42.00"),
      cash_balance: BigDecimal("42.00")
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "partial",
      "domain_statuses" => { "account_metadata" => "success", "cash" => "failed", "portfolio" => "success", "timeline" => "success" },
      "account" => { "brokerage_account_id" => "DE-MALFORMED", "currency" => "EUR" },
      "positions" => [], "events" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    assert_equal BigDecimal("42.00"), cash.reload.current_balance
    assert_equal BigDecimal("42.00"), cash.cash_balance
  end

  test "malformed account payload preserves all existing financial data" do
    account = @item.trade_republic_accounts.create!(
      kind: "portfolio",
      trade_republic_account_id: "DE-KEEP",
      currency: "EUR",
      current_balance: BigDecimal("123.45"),
      raw_positions_payload: [ { "isin" => "KEEP", "quantity" => "1", "price" => "123.45" } ],
      raw_timeline_payload: [ { "id" => "keep-event" } ]
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "partial",
      "domain_statuses" => { "account_metadata" => "failed", "cash" => "success", "portfolio" => "success", "timeline" => "success" },
      "cash" => { "amount" => "0", "currency" => "EUR" },
      "positions" => [], "events" => []
    ))

    assert_raises(Provider::TradeRepublicClient::MalformedResponse) do
      TradeRepublicItem::Importer.new(@item, provider: provider).import
    end

    account.reload
    assert_equal BigDecimal("123.45"), account.current_balance
    assert_equal [ "KEEP" ], account.raw_positions_payload.map { |position| position["isin"] }
    assert_equal [ "keep-event" ], account.raw_timeline_payload.map { |event| event["id"] }
  end

  test "cash timeline retains saveback and round up aggregates while excluding order executions" do
    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE-AGG", "currency" => "EUR" },
      "cash" => { "amount" => "10.00", "currency" => "EUR" },
      "positions" => [],
      "events" => [
        { "id" => "trade-1", "eventType" => "TRADING_TRADE_EXECUTED", "category" => "orderExecution" },
        { "id" => "saveback-1", "eventType" => "SAVEBACK_AGGREGATE", "category" => "POC_CREATED" },
        { "id" => "roundup-1", "eventType" => "SPARE_CHANGE_AGGREGATE", "category" => "POC_CREATED" }
      ],
      "newest_event_id" => "roundup-1",
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    portfolio = @item.trade_republic_accounts.find_by!(kind: "portfolio")
    cash = @item.trade_republic_accounts.find_by!(kind: "cash")

    assert_equal %w[trade-1 saveback-1 roundup-1], portfolio.raw_timeline_payload.map { |event| event["id"] }
    assert_equal %w[saveback-1 roundup-1], cash.raw_timeline_payload.map { |event| event["id"] }
    assert cash.raw_timeline_payload.none? { |event| event["category"] == "orderExecution" }
  end

  test "passes oldest incomplete trade-detail events for targeted enrichment" do
    incomplete_trade = {
      "id" => "trade-old",
      "timestamp" => "2026-05-01T10:00:00Z",
      "eventType" => "TRADING_TRADE_EXECUTED",
      "category" => "orderExecution",
      "detail" => { "amount" => -100.0, "currency" => "EUR" }
    }
    incomplete_savings = {
      "id" => "savings-old",
      "timestamp" => "2026-06-17T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "detail" => { "amount" => -25.0, "currency" => "EUR" }
    }
    incomplete_saveback = {
      "id" => "saveback-old",
      "timestamp" => "2026-07-01T10:00:00Z",
      "eventType" => "SAVEBACK_AGGREGATE",
      "category" => "POC_CREATED",
      "detail" => { "amount" => -3.74, "currency" => "EUR" }
    }
    complete = {
      "id" => "savings-done",
      "timestamp" => "2026-08-01T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "category" => "orderExecution",
      "detail" => { "amount" => -25.0, "isin" => "IE00B4L5Y983", "quantity" => "0.25" }
    }
    @item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio",
      trade_republic_account_id: "DE-ENRICH",
      currency: "EUR",
      raw_timeline_payload: [ incomplete_saveback, complete, incomplete_savings, incomplete_trade ]
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).with { |args|
      enrich_ids = Array(args[:enrich_events]).map { |event| event["id"] || event[:id] }
      enrich_ids == %w[trade-old savings-old saveback-old]
    }.returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE-ENRICH", "currency" => "EUR" },
      "cash" => { "amount" => "1", "currency" => "EUR" },
      "positions" => [],
      "events" => [],
      "newest_event_id" => "savings-done",
      "timeline_pagination_complete" => true,
      "detail_backfill_count" => 0,
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import
  end

  test "advances newest_event_id when pagination completes with a detail backlog" do
    incomplete = {
      "id" => "savings-old",
      "timestamp" => "2026-06-17T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "detail" => { "amount" => -25.0, "currency" => "EUR" }
    }
    @item.update!(newest_event_id: "old-cursor")
    @item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio",
      trade_republic_account_id: "DE-CURSOR",
      currency: "EUR",
      raw_timeline_payload: [ incomplete ]
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "partial",
      "domain_statuses" => {
        "account_metadata" => "success",
        "cash" => "success",
        "portfolio" => "success",
        "timeline" => "success",
        "instrument_metadata" => "success"
      },
      "account" => { "brokerage_account_id" => "DE-CURSOR", "currency" => "EUR" },
      "cash" => { "amount" => "1", "currency" => "EUR" },
      "positions" => [],
      "events" => [ incomplete ],
      "newest_event_id" => "new-cursor",
      "timeline_pagination_complete" => true,
      "detail_backfill_count" => 0,
      "warnings" => [ "detail fetch failed for event savings-old" ]
    ))

    result = TradeRepublicItem::Importer.new(@item, provider: provider).import

    assert_equal "new-cursor", @item.reload.newest_event_id
    assert_equal 0, result[:detail_backfill_count]
    assert_equal 1, @item.data_quality_summary[:pending_trade_details]
  end

  test "progressively enrichs incomplete portfolio events across syncs" do
    first = {
      "id" => "savings-1",
      "timestamp" => "2026-01-01T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "detail" => { "amount" => -25.0, "currency" => "EUR" }
    }
    second = {
      "id" => "savings-2",
      "timestamp" => "2026-02-01T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "detail" => { "amount" => -30.0, "currency" => "EUR" }
    }
    portfolio = @item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio",
      trade_republic_account_id: "DE-MULTI",
      currency: "EUR",
      raw_timeline_payload: [ first, second ]
    )

    enriched_first = first.merge(
      "category" => "orderExecution",
      "detail" => first["detail"].merge("isin" => "IE00B4L5Y983", "quantity" => "0.25")
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).twice.returns(
      client_result(
        "status" => "ok",
        "session_txt" => "# refreshed cookies",
        "account" => { "brokerage_account_id" => "DE-MULTI", "currency" => "EUR" },
        "cash" => { "amount" => "1", "currency" => "EUR" },
        "positions" => [],
        "events" => [ enriched_first ],
        "newest_event_id" => "cursor-1",
        "timeline_pagination_complete" => true,
        "detail_backfill_count" => 1,
        "warnings" => []
      ),
      client_result(
        "status" => "ok",
        "session_txt" => "# refreshed cookies",
        "account" => { "brokerage_account_id" => "DE-MULTI", "currency" => "EUR" },
        "cash" => { "amount" => "1", "currency" => "EUR" },
        "positions" => [],
        "events" => [ second.merge(
          "category" => "orderExecution",
          "detail" => second["detail"].merge("isin" => "US0378331005", "quantity" => "0.10")
        ) ],
        "newest_event_id" => "cursor-1",
        "timeline_pagination_complete" => true,
        "detail_backfill_count" => 1,
        "warnings" => []
      )
    )

    first_result = TradeRepublicItem::Importer.new(@item, provider: provider).import
    assert_equal 1, first_result[:detail_backfill_count]
    stored_after_first = portfolio.reload.raw_timeline_payload.index_by { |event| event["id"] }
    assert_equal "IE00B4L5Y983", stored_after_first["savings-1"].dig("detail", "isin")
    assert_nil stored_after_first["savings-2"].dig("detail", "isin")
    assert_equal 1, @item.data_quality_summary[:pending_trade_details]

    second_result = TradeRepublicItem::Importer.new(@item, provider: provider).import
    assert_equal 1, second_result[:detail_backfill_count]
    stored_after_second = portfolio.reload.raw_timeline_payload.index_by { |event| event["id"] }
    assert_equal "IE00B4L5Y983", stored_after_second["savings-1"].dig("detail", "isin")
    assert_equal "0.25", stored_after_second["savings-1"].dig("detail", "quantity")
    assert_equal "US0378331005", stored_after_second["savings-2"].dig("detail", "isin")
    assert_equal 0, @item.data_quality_summary[:pending_trade_details]
  end

  test "backfills an amount-only savings-plan event and removes the stale cash copy" do
    incomplete = {
      "id" => "savings-1",
      "timestamp" => "2026-06-17T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "detail" => { "amount" => -25.0, "currency" => "EUR" }
    }
    @item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio",
      trade_republic_account_id: "DE-BACKFILL",
      currency: "EUR",
      raw_timeline_payload: [ incomplete ]
    )
    cash = @item.trade_republic_accounts.create!(
      kind: "cash",
      name: "Cash",
      trade_republic_account_id: "cash:DE-BACKFILL",
      currency: "EUR",
      raw_timeline_payload: [ incomplete ]
    )

    enriched = incomplete.merge(
      "category" => "orderExecution",
      "detail" => {
        "amount" => -25.0,
        "currency" => "EUR",
        "isin" => "IE00B4L5Y983",
        "quantity" => "0.25",
        "name" => "MSCI World"
      }
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE-BACKFILL", "currency" => "EUR" },
      "cash" => { "amount" => "10.00", "currency" => "EUR" },
      "positions" => [],
      "events" => [ enriched ],
      "newest_event_id" => "savings-1",
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    portfolio = @item.trade_republic_accounts.find_by!(kind: "portfolio")
    stored = portfolio.reload.raw_timeline_payload.find { |event| event["id"] == "savings-1" }

    assert_equal "orderExecution", stored["category"]
    assert_equal "IE00B4L5Y983", stored.dig("detail", "isin")
    assert_equal "0.25", stored.dig("detail", "quantity")
    assert cash.reload.raw_timeline_payload.none? { |event| event["id"] == "savings-1" }
  end

  test "preserves enriched savings-plan details when a thin timeline copy reappears" do
    rich = {
      "id" => "savings-1",
      "timestamp" => "2026-06-17T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "category" => "orderExecution",
      "detail" => {
        "amount" => -25.0,
        "currency" => "EUR",
        "isin" => "IE00B4L5Y983",
        "quantity" => "0.25"
      }
    }
    @item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio",
      trade_republic_account_id: "DE-RICH",
      currency: "EUR",
      raw_timeline_payload: [ rich ]
    )

    thin = {
      "id" => "savings-1",
      "timestamp" => "2026-06-17T10:00:00Z",
      "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
      "category" => "orderExecution",
      "detail" => { "amount" => -25.0, "currency" => "EUR" }
    }

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(client_result(
      "status" => "ok",
      "session_txt" => "# refreshed cookies",
      "account" => { "brokerage_account_id" => "DE-RICH", "currency" => "EUR" },
      "cash" => { "amount" => "1", "currency" => "EUR" },
      "positions" => [],
      "events" => [ thin ],
      "newest_event_id" => "savings-1",
      "warnings" => []
    ))

    TradeRepublicItem::Importer.new(@item, provider: provider).import

    stored = @item.trade_republic_accounts.find_by!(kind: "portfolio").reload.raw_timeline_payload.first
    assert_equal "IE00B4L5Y983", stored.dig("detail", "isin")
    assert_equal "0.25", stored.dig("detail", "quantity")
    assert_equal "EUR", stored.dig("detail", "currency")
  end

  test "prefer_richer_timeline_event merges newer lifecycle fields including false flags" do
    importer = TradeRepublicItem::Importer.new(@item, provider: mock("provider"))
    previous = {
      id: "card-1",
      category: "POC_CREATED",
      status: "AUTHORIZED",
      deleted: true,
      hidden: true,
      detail: { amount: -10.0, isin: "US0378331005" }
    }
    incoming = {
      id: "card-1",
      category: "POC_CREATED",
      status: "EXECUTED",
      deleted: false,
      hidden: false,
      detail: { amount: -10.0, currency: "EUR" }
    }

    merged = importer.send(:prefer_richer_timeline_event, previous, incoming)

    assert_equal "EXECUTED", merged[:status]
    assert_equal false, merged[:deleted]
    assert_equal false, merged[:hidden]
    assert_equal "US0378331005", merged.dig(:detail, :isin)
    assert_equal "EUR", merged.dig(:detail, :currency)
  end

  test "events needing detail enrichment exclude non-importable lifecycle events" do
    @item.trade_republic_accounts.create!(
      kind: "portfolio",
      name: "Portfolio",
      trade_republic_account_id: "DE-ENRICH",
      currency: "EUR",
      raw_timeline_payload: [
        {
          "id" => "declined-savings",
          "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
          "category" => "orderExecution",
          "status" => "DECLINED",
          "detail" => { "amount" => -25.0 }
        },
        {
          "id" => "admin-verify",
          "eventType" => "CARD_VERIFICATION"
        },
        {
          "id" => "incomplete-ok",
          "eventType" => "SAVINGS_PLAN_INVOICE_CREATED",
          "category" => "orderExecution",
          "status" => "EXECUTED",
          "detail" => { "amount" => -25.0 }
        }
      ]
    )

    enrich_ids = TradeRepublicItem::Importer.new(@item, provider: mock("provider"))
      .send(:events_needing_detail_enrichment)
      .map { |event| event["id"] || event[:id] }

    assert_equal [ "incomplete-ok" ], enrich_ids
  end

  private

    def client_result(data)
      Provider::TradeRepublicClient::Result.new(data: data)
    end
end
