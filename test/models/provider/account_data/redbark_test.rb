require "test_helper"
require "ostruct"

class Provider::AccountData::RedbarkTest < ActiveSupport::TestCase
  setup do
    @client = mock("Redbark transport")
    @adapter = build_adapter
    @account = account_record
    @window = { start: "2026-01-01", end: "2026-01-31" }
  end

  test "transaction normalization matches legacy identity signs dates currency merchant notes and metadata" do
    raw = transaction(merchantName: " Bakery ", category: "food", merchantCategoryCode: "5812", currency: "EUR")
    linked = OpenStruct.new(currency: "AUD")
    legacy = OpenStruct.new(current_account: linked)
    importer = mock("legacy ledger boundary")
    merchant = OpenStruct.new(name: "Bakery")
    Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
    importer.expects(:find_or_create_merchant).with(provider_merchant_id: "redbark_merchant_#{Digest::SHA256.hexdigest('bakery')[0, 32]}",
      name: "Bakery", source: "redbark").returns(merchant)
    imported = nil
    importer.expects(:import_transaction).with { |**attributes| imported = attributes }.returns(:entry)
    assert_equal :entry, RedbarkAccount::Transactions::Processor.new(legacy).send(:process_transaction, raw)

    normalized = @adapter.normalize_transaction(raw, account: @account)

    %i[external_id amount date name currency].each { |key| assert_equal imported[key], normalized[key] }
    assert_equal imported[:extra], normalized[:metadata][:extra]
    assert_equal imported[:notes], normalized[:metadata][:notes]
    assert_equal merchant.name, normalized[:metadata][:merchant][:name]
    assert_equal "AUD", normalized[:currency]
  end

  test "native monetary values remain exact and legacy floats have an explicit conversion entry point" do
    raw = transaction(amount: "-123456789.123456789012345678")
    assert_equal BigDecimal("123456789.123456789012345678"), @adapter.normalize_transaction(raw, account: @account)[:amount]
    assert_equal BigDecimal("1.25"), @adapter.normalize_legacy_transaction(transaction(amount: -1.25), account: @account)[:amount]
    [ nil, "unavailable", "NaN", Float::INFINITY, -1.25 ].each do |amount|
      error = assert_raises(Provider::AccountData::InvalidResponse) do
        @adapter.normalize_transaction(transaction(amount: amount), account: @account)
      end
      assert_nil error.cause
    end
  end

  test "pending filtering name truncation date precedence and timezone match the existing bank semantics" do
    pending = transaction(status: "pending", description: "x" * 300, merchantName: nil, date: nil, postDate: "2026-01-14")
    record = @adapter.normalize_transaction(pending, account: @account)
    assert record[:pending]
    assert_equal "x" * 255, record[:name]
    assert_equal "x" * 300, record[:metadata][:notes]
    assert_equal Date.new(2026, 1, 14), record[:date]
    assert_nil build_adapter(include_pending: false).normalize_transaction(pending, account: @account)
    timestamp = transaction(date: "2026-01-14T15:30:00Z", postDate: "2026-01-17")
    assert_equal Date.new(2026, 1, 15), @adapter.normalize_transaction(timestamp, account: @account)[:date]
    assert_equal false, @adapter.normalize_transaction(transaction(status: "posted"), account: @account)[:pending]
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.normalize_transaction(transaction(accountId: "another-account"), account: @account)
    end
  end

  test "inventory is paged under one credential with account institutions and document scope preserved" do
    @client.expects(:list_connections_snapshot).once.returns(envelope([ connection,
      connection(id: "document-connection", category: "documents"), connection(id: "broker-connection", category: "brokerage") ], paginate: false))
    @client.expects(:list_accounts_page).with(offset: 0).returns(envelope([
      account_snapshot, account_snapshot(id: "documents", connectionId: "document-connection"),
      account_snapshot(id: "brokerage", connectionId: "broker-connection")
    ], has_more: true))
    @client.expects(:list_accounts_page).with(offset: 3).returns(envelope([
      account_snapshot(id: "other-bank", institutionName: "Other Bank", currency: { code: "NZD" })
    ]))

    first = @adapter.list_accounts
    second = @adapter.list_accounts(cursor: first.next_cursor)

    assert_not first.complete?
    assert_equal %w[rb-account documents], first.records.map { |record| record[:external_id] }
    assert second.complete?
    assert_equal "Other Bank - Everyday", second.records.sole[:name]
    assert_equal "NZD", second.records.sole[:currency]
    assert_equal "connection-1", first.records.first[:metadata][:connection_id]
    assert_equal "documents", first.records.last[:metadata][:connection_category]
    assert_nil first.records.first[:balance]
    assert_equal "private-account-number", first.records.first[:sensitive_details][:account_number]
    refute_includes first.records.first[:metadata].to_json, "private-account-number"
    assert_equal 3, first.evidence.fetch("accounts").fetch("response").fetch("data").size
    assert_nil @adapter.normalize_account(account_snapshot(currency: nil))[:currency]
  end

  test "metadata fetch failures keep healthy accounts but cannot assert complete inventory" do
    @client.expects(:list_accounts_page).returns(envelope([ account_snapshot ]))
    @client.expects(:list_connections_snapshot).raises(Provider::Redbark::Error.new("private remote details", :server_error))

    page = @adapter.list_accounts

    assert_equal 1, page.records.size
    assert_not page.complete?
    assert_nil page.next_cursor
    assert_equal "connections_unavailable", page.warnings.sole.fetch("code")
    refute_includes page.warnings.to_json, "private"
    refute_includes page.evidence.to_json, "private remote details"
  end

  test "authentication failure retrieving connection metadata remains fatal" do
    @client.expects(:list_accounts_page).returns(envelope([ account_snapshot ]))
    @client.expects(:list_connections_snapshot).raises(Provider::Redbark::AuthenticationError.new("authentication", :unauthorized))
    assert_raises(Provider::Redbark::AuthenticationError) { @adapter.list_accounts }
  end

  test "balance zero is an observation missing balance is incomplete and document balance is unsupported" do
    @client.expects(:get_balances_snapshot).with(account_ids: [ "rb-account" ]).returns(envelope([
      { accountId: "rb-account", currentBalance: "0", availableBalance: "12.34", currency: "AUD" }
    ], paginate: false))
    page = @adapter.fetch_balance(account: @account)
    assert page.complete?
    assert_equal BigDecimal("0"), page.records.sole[:balance]
    assert_equal BigDecimal("12.34"), page.records.sole[:available_balance]
    assert_equal true, page.records.sole[:metadata][:balance_policy][:current_anchor]
    assert_equal "negate", page.records.sole[:metadata][:balance_policy][:debt_transform]

    @client.expects(:get_balances_snapshot).returns(envelope([], paginate: false))
    missing = @adapter.fetch_balance(account: @account)
    assert_not missing.complete?
    assert_nil missing.records.sole[:balance]
    assert_equal false, missing.records.sole[:metadata][:balance_provided]

    unsupported = @adapter.fetch_balance(account: account_record(category: "documents"))
    assert unsupported.complete?
    assert_nil unsupported.records.sole[:balance]
    assert_equal false, unsupported.coverage.fetch("supported")
    assert_equal false, unsupported.evidence.fetch("balance_endpoint_supported")
  end

  test "invalid balances retain evidence and cannot supply a synthetic currency or current balance" do
    @client.expects(:get_balances_snapshot).returns(envelope([
      { accountId: "rb-account", currentBalance: "unavailable", currency: "AUD" }
    ], paginate: false))
    page = @adapter.fetch_balance(account: @account)
    assert_not page.complete?
    assert_nil page.records.sole[:balance]
    assert_equal "unavailable", page.evidence.fetch("response").fetch("response").fetch("data").sole.fetch("currentBalance")
    raw = { accountId: "rb-account", currentBalance: "1", currency: nil }
    assert_equal "AUD", @adapter.normalize_balance(raw, account: @account)[:currency]
    unknown = Ingestion::Record.account(external_id: "rb-account", name: "Unknown", currency: nil)
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_balance(raw, account: unknown) }
  end

  test "transaction continuation requests one offset page and preserves original scope through completion" do
    expect_transaction_page(start_date: "2026-01-01", end_date: "2026-01-31", offset: 0,
      response: envelope([ transaction ], has_more: true))
    expect_transaction_page(start_date: "2026-01-01", end_date: "2026-01-31", offset: 1,
      response: envelope([ transaction(id: "second") ]))

    first = @adapter.fetch_transactions(account: @account, window: @window)
    second = @adapter.fetch_transactions(account: @account, window: @window, cursor: first.next_cursor)

    assert_not first.complete?
    assert second.complete?
    assert_equal %w[redbark_tx-1 redbark_second], (first.records + second.records).map { |record| record[:external_id] }
    assert_equal first.coverage.fetch("start"), second.coverage.fetch("start")
    assert_equal false, second.coverage.fetch("pending_absence_authoritative")
  end

  test "truncated windows split into bounded explicit requests without importing partial parent records" do
    expect_transaction_page(start_date: "2026-01-01", end_date: "2026-01-31", response: envelope([ transaction ], truncated: true))
    expect_transaction_page(start_date: "2026-01-01", end_date: "2026-01-16", response: envelope([ transaction ]))
    expect_transaction_page(start_date: "2026-01-17", end_date: "2026-01-31", response: envelope([ transaction(id: "second", date: "2026-01-20") ]))

    split = @adapter.fetch_transactions(account: @account, window: @window)
    first = @adapter.fetch_transactions(account: @account, window: @window, cursor: split.next_cursor)
    last = @adapter.fetch_transactions(account: @account, window: @window, cursor: first.next_cursor)

    assert_empty split.records
    assert_equal "split_window", split.evidence.fetch("recovery")
    assert_equal "true", split.evidence.fetch("response").fetch("pagination_headers").fetch("x-redbark-truncated")
    assert_not first.complete?
    assert last.complete?
    assert_equal first.coverage.fetch("start"), last.coverage.fetch("start")
    assert_equal first.coverage.fetch("end"), last.coverage.fetch("end")
    assert_equal [ "2026-01-17", "2026-01-31" ], last.coverage.values_at("page_start", "page_end")
  end

  test "single day truncation incomplete envelopes and partial rows never advance a checkpoint" do
    expect_transaction_page(start_date: "2026-01-15", end_date: "2026-01-15", response: envelope([ transaction ], truncated: true))
    page = @adapter.fetch_transactions(account: @account, window: { start: "2026-01-15", end: "2026-01-15" })
    assert_not page.complete?
    assert_nil page.next_cursor
    assert_empty page.records
    assert_equal "truncated_window", page.warnings.sole.fetch("code")

    [ envelope([], has_more: true), envelope([ transaction ], paginate: false),
      envelope([ transaction, transaction(id: nil) ]), envelope([ transaction ], total: 9) ].each do |response|
      @client.expects(:get_transactions_page).returns(response)
      partial = @adapter.fetch_transactions(account: @account, window: @window)
      assert_not partial.complete?
      assert_nil partial.next_cursor
      assert_nil partial.checkpoint_cursor
    end
  end

  test "continuation cannot switch account pending preference connection or original date scope" do
    @client.expects(:get_transactions_page).returns(envelope([ transaction ], has_more: true))
    first = @adapter.fetch_transactions(account: @account, window: @window)
    [ [ @adapter, account_record(external_id: "other"), @window ],
      [ @adapter, account_record(connection_id: "other"), @window ],
      [ build_adapter(include_pending: false), @account, @window ],
      [ @adapter, @account, @window.merge(start: "2025-12-01") ] ].each do |adapter, account, window|
      assert_raises(Provider::AccountData::InvalidResponse) do
        adapter.fetch_transactions(account: account, window: window, cursor: first.next_cursor)
      end
    end
  end

  test "server pagination and truncation recovery both terminate at their explicit bounds" do
    @client.expects(:get_transactions_page).times(50).returns(envelope([ transaction ], has_more: true))
    cursor = nil
    result = nil
    50.times do
      result = @adapter.fetch_transactions(account: @account, window: @window, cursor: cursor)
      cursor = result.next_cursor
    end
    assert_nil cursor
    assert_not result.complete?
    assert_equal "page_limit", result.warnings.sole.fetch("code")

    @client.expects(:get_transactions_page).times(7).returns(envelope([ transaction ], truncated: true))
    cursor = nil
    7.times do
      result = @adapter.fetch_transactions(account: @account, window: { start: "2020-01-01", end: "2030-12-31" }, cursor: cursor)
      cursor = result.next_cursor
    end
    assert_nil cursor
    assert_not result.complete?
    assert_empty result.records
    assert_equal "truncated_window", result.warnings.sole.fetch("code")
  end

  test "incremental history uses the seven day checkpoint overlap instead of repeating the original backfill" do
    expect_transaction_page(start_date: "2026-01-13", end_date: "2026-01-31", response: envelope([]))
    result = @adapter.fetch_transactions(account: @account,
      window: @window.merge(start: "2020-01-01", initial: false, checkpoint_covered_through: "2026-01-20T00:00:00Z"))
    assert result.complete?
    assert_equal "2026-01-13", result.coverage.fetch("page_start")
  end

  test "duplicate transaction observations retain last response value and malformed inventory remains partial" do
    @client.expects(:get_transactions_page).returns(envelope([
      transaction(status: "pending", amount: "-20"), transaction(status: "posted", amount: "-21")
    ]))
    page = @adapter.fetch_transactions(account: @account, window: @window)
    assert page.complete?
    assert_equal BigDecimal("21"), page.records.sole[:amount]
    assert_equal false, page.records.sole[:pending]

    @client.expects(:list_connections_snapshot).returns(envelope([ connection ], paginate: false))
    @client.expects(:list_accounts_page).returns(envelope([ account_snapshot, account_snapshot, account_snapshot(id: "healthy") ]))
    inventory = @adapter.list_accounts
    assert_not inventory.complete?
    assert_equal [ "healthy" ], inventory.records.map { |record| record[:external_id] }
    assert_not Provider::AccountData::Redbark.native_ready?
  end

  private
    def build_adapter(**attributes)
      Provider::AccountData::Redbark.new(**{
        client: @client, timezone: "Australia/Sydney", observed_at: Time.utc(2026, 1, 31), include_pending: true
      }.merge(attributes))
    end

    def account_record(external_id: "rb-account", connection_id: "connection-1", category: "banking")
      Ingestion::Record.account(external_id: external_id, name: "Everyday", currency: "AUD",
        metadata: { connection_id: connection_id, connection_category: category })
    end

    def account_snapshot(**attributes)
      { id: "rb-account", connectionId: "connection-1", name: "Everyday", type: "savings", currency: "AUD",
        institutionName: "Example Bank", provider: "basiq", accountNumber: "private-account-number" }.merge(attributes)
    end

    def connection(**attributes)
      { id: "connection-1", category: "banking", institutionName: "Example Bank", institutionId: "bank-1",
        institutionLogo: "https://bank.example/logo.png", status: "active" }.merge(attributes)
    end

    def transaction(**attributes)
      { id: "tx-1", accountId: "rb-account", status: "posted", date: "2026-01-15", postDate: "2026-01-16",
        description: "Coffee purchase", merchantName: "Bakery", amount: "-12.3456", direction: "debit" }.merge(attributes)
    end

    def envelope(rows, has_more: false, truncated: false, paginate: true, total: nil)
      response = { data: rows }
      response[:pagination] = { hasMore: has_more } if paginate
      response[:total] = total unless total.nil?
      { "response" => response.deep_stringify_keys,
        "pagination_headers" => truncated ? { "x-redbark-truncated" => "true" } : {} }
    end

    def expect_transaction_page(start_date:, end_date:, response:, offset: 0)
      @client.expects(:get_transactions_page).with(connection_id: "connection-1", account_id: "rb-account",
        start_date: Date.iso8601(start_date), end_date: Date.iso8601(end_date), include_pending: true, offset: offset).returns(response)
    end
end
