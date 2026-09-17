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

    assert_equal({ success: true }, result)

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

    assert_equal 2, @item.reload.data_quality_summary[:events]
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

  private

    def client_result(data)
      Provider::TradeRepublicClient::Result.new(data: data)
    end
end
