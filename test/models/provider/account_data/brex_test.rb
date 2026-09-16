require "test_helper"
require "ostruct"

class Provider::AccountData::BrexTest < ActiveSupport::TestCase
  setup do
    @client = mock("Brex transport")
    @adapter = Provider::AccountData::Brex.new(client: @client, timezone: "America/Los_Angeles")
    @card = Ingestion::Record.account(external_id: "card_primary", name: "Brex Card", currency: "USD", metadata: { account_kind: "card" })
    @cash = Ingestion::Record.account(external_id: "cash-1", name: "Operating", currency: "USD", metadata: { account_kind: "cash" })
  end

  test "valid transaction fields and merchant hints match the legacy importer" do
    raw = transaction(
      type: "COLLECTION", amount: { amount: -1234, currency: "USD" }, expense_id: "expense-1", card_id: "card-1",
      transfer_id: "transfer-1", card_transaction_operation_reference_id: "operation-1",
      merchant: { raw_descriptor: "  ACME INC  ", card_metadata: { pan: "private-card-number", card_name: "Operations" }, access_token: "private-token" }
    )
    linked = OpenStruct.new(family: OpenStruct.new(timezone: "America/Los_Angeles"))
    legacy = OpenStruct.new(current_account: linked, account_kind: "card", currency: "USD", id: "legacy-account")
    importer = mock("ledger importer")
    merchant = OpenStruct.new(name: "ACME INC")
    Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
    importer.expects(:find_or_create_merchant).with(
      provider_merchant_id: "brex_merchant_#{Digest::MD5.hexdigest('acme inc')}", name: "ACME INC", source: "brex"
    ).returns(merchant)
    imported = nil
    importer.expects(:import_transaction).with { |**attributes| imported = attributes }.returns(:entry)

    # Pure normalization parity; real publication admission has its own DB tests.
    assert_equal :entry, BrexEntry::Processor.new(raw, brex_account: legacy).send(:process_admitted)
    normalized = @adapter.normalize_transaction(raw, account: @card)
    %i[external_id name amount currency date].each { |key| assert_equal imported[key], normalized[key] }
    assert_equal imported[:kind], normalized[:metadata][:kind]
    assert_equal imported[:notes], normalized[:metadata][:notes]
    assert_equal imported[:extra], normalized[:metadata][:extra]
    assert_equal merchant.name, normalized[:metadata][:merchant][:name]
    refute_includes normalized[:metadata][:extra].inspect, "private-card-number"
    refute_includes normalized[:metadata][:extra].inspect, "private-token"
  end

  test "minor units preserve exact signs for purchases refunds and zero decimal currencies" do
    purchase = @adapter.normalize_transaction(transaction(amount: { amount: 9_007_199_254_740_993, currency: "USD" }), account: @card)
    refund = @adapter.normalize_transaction(transaction(amount: { amount: -1234, currency: "USD" }), account: @card)
    yen = @adapter.normalize_transaction(transaction(amount: { amount: 1234, currency: "JPY" }), account: @cash)

    assert_equal BigDecimal("90071992547409.93"), purchase[:amount]
    assert_equal BigDecimal("-12.34"), refund[:amount]
    assert_equal BigDecimal("1234"), yen[:amount]
    assert_equal "JPY", yen[:currency]
    assert_equal false, purchase[:pending]
  end

  test "legacy normalization converts only historical monetary floats explicitly" do
    raw = transaction(amount: { amount: 1234.0, currency: "USD" })
    assert_equal BigDecimal("12.34"), @adapter.normalize_legacy_transaction(raw, account: @card)[:amount]
    assert_instance_of Float, raw[:amount][:amount]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @card) }
    snapshot = account_snapshot(current_balance: { amount: 12345.0, currency: "USD" })
    assert_equal BigDecimal("123.45"), @adapter.normalize_legacy_account(snapshot)[:balance]
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.normalize_legacy_transaction(transaction(amount: { amount: Float::INFINITY, currency: "USD" }), account: @card)
    end
  end

  test "only negative card collections become credit card payments" do
    payment = transaction(type: "COLLECTION", amount: { amount: -5000, currency: "USD" })
    assert_equal "cc_payment", @adapter.normalize_transaction(payment, account: @card)[:metadata][:kind]
    assert_nil @adapter.normalize_transaction(payment, account: @cash)[:metadata][:kind]
    assert_nil @adapter.normalize_transaction(payment.merge(amount: { amount: 5000, currency: "USD" }), account: @card)[:metadata][:kind]
  end

  test "description merchant and localized defaults preserve name priority" do
    raw = transaction(description: nil, merchant: { raw_descriptor: "Descriptor", name: "Merchant" })
    assert_equal "Descriptor", @adapter.normalize_transaction(raw, account: @cash)[:name]
    assert_equal "Merchant", @adapter.normalize_transaction(raw.merge(merchant: { name: "Merchant" }), account: @cash)[:name]
    record = @adapter.normalize_transaction(raw.merge(merchant: nil, type: nil), account: @cash)
    assert_equal I18n.t("brex_items.entries.default_name"), record[:name]
    assert_nil record[:metadata][:merchant]
    assert_nil record[:metadata][:notes]
  end

  test "dates retain posting preference and the family timezone" do
    record = @adapter.normalize_transaction(transaction(posted_at_date: "2026-01-02T01:00:00Z"), account: @card)
    assert_equal Date.new(2026, 1, 1), record[:date]
    initiated = @adapter.normalize_transaction(transaction(posted_at_date: nil, initiated_at_date: "2026-01-03"), account: @card)
    assert_equal Date.new(2026, 1, 3), initiated[:date]
  end

  test "cash accounts preserve balances available credit hints and sensitive metadata" do
    raw = account_snapshot(account_number: "123456789012", routing_number: "987654321", current_statement_period: { start_date: "2026-01-01" })
    record = @adapter.normalize_account(raw)

    assert_equal "cash-1", record[:external_id]
    assert_equal BigDecimal("123.45"), record[:balance]
    assert_equal record[:balance], record[:cash_balance]
    assert_equal BigDecimal("1000"), record[:available_balance]
    assert_equal "2500.0", record[:metadata][:account_limit]
    assert_equal "9012", record[:sensitive_details][:account_number_last4]
    refute_includes record[:metadata].inspect, "9012"
    refute_includes record.inspect, "123456789012"
    assert_equal({ debt_transform: "preserve", debt_types: [], cash_balance: "balance", available_credit: "available_balance" }, record[:metadata][:balance_policy])
  end

  test "cash pages and physical card pages produce one stable aggregate card account" do
    @client.expects(:get_cash_accounts_page).with(cursor: nil).returns(items: [ account_snapshot ], next_cursor: "cash-next")
    @client.expects(:get_cash_accounts_page).with(cursor: "cash-next").returns(items: [], next_cursor: nil)
    @client.expects(:get_card_accounts_page).with(cursor: nil).returns(items: [ account_snapshot(id: "physical-card-1", current_balance: { amount: 1000, currency: "USD" }) ], next_cursor: "card-next")
    @client.expects(:get_card_accounts_page).with(cursor: "card-next").returns(items: [ account_snapshot(id: "physical-card-2", current_balance: { amount: -200, currency: "USD" }) ], next_cursor: nil)

    cash_page = @adapter.list_accounts
    assert_equal [ "cash-1" ], cash_page.records.map { |record| record[:external_id] }
    refute cash_page.complete?
    transition_page = @adapter.list_accounts(cursor: cash_page.next_cursor)
    refute transition_page.complete?
    first_card_page = @adapter.list_accounts(cursor: transition_page.next_cursor)
    assert_empty first_card_page.records
    refute first_card_page.complete?

    # A fresh object simulates job recovery: aggregation state is in the cursor.
    recovered = Provider::AccountData::Brex.new(client: @client, timezone: "America/Los_Angeles")
    final_page = recovered.list_accounts(cursor: first_card_page.next_cursor)
    assert final_page.complete?
    assert_equal [ "card_primary" ], final_page.records.map { |record| record[:external_id] }
    assert_equal BigDecimal("8"), final_page.records.first[:balance]
    assert_equal BigDecimal("2000"), final_page.records.first[:available_balance]
    assert_equal 2, final_page.records.first[:metadata][:card_accounts_count]
    assert_equal "physical-card-1", first_card_page.evidence["response"][:items].first[:id]
    assert_equal "physical-card-2", final_page.evidence["response"][:items].first[:id]
    refute_includes final_page.records.first[:metadata].inspect, "physical-card-2"
  end

  test "no card account is invented when both inventories are empty" do
    @client.expects(:get_cash_accounts_page).with(cursor: nil).returns(items: [], next_cursor: nil)
    @client.expects(:get_card_accounts_page).with(cursor: nil).returns(items: [], next_cursor: nil)
    first = @adapter.list_accounts
    final = @adapter.list_accounts(cursor: first.next_cursor)

    assert final.complete?
    assert_empty final.records
  end

  test "mixed currency aggregates fail instead of becoming zero company balances" do
    @client.expects(:get_cash_accounts_page).with(cursor: nil).returns(items: [], next_cursor: nil)
    @client.expects(:get_card_accounts_page).with(cursor: nil).returns(
      items: [ account_snapshot, account_snapshot(id: "euro-card", current_balance: { amount: 100, currency: "EUR" }) ], next_cursor: nil
    )
    first = @adapter.list_accounts
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.list_accounts(cursor: first.next_cursor) }
  end

  test "repeated inventory cursors fail even though aggregation state changes" do
    @client.expects(:get_cash_accounts_page).with(cursor: nil).returns(items: [], next_cursor: "repeat")
    @client.expects(:get_cash_accounts_page).with(cursor: "repeat").returns(items: [], next_cursor: "repeat")
    first = @adapter.list_accounts
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.list_accounts(cursor: first.next_cursor) }
  end

  test "card and cash transactions use distinct endpoints and report lower-bound coverage" do
    window = { "start" => "2026-01-01T00:00:00Z", "end" => "2026-02-01T00:00:00Z" }
    @client.expects(:get_primary_card_transactions_page).with(cursor: "card-page", start_date: window["start"]).returns(items: [ transaction ], next_cursor: nil)
    @client.expects(:get_cash_transactions_page).with("cash-1", cursor: nil, start_date: window["start"]).returns(items: [], next_cursor: "cash-page")

    card_page = @adapter.fetch_transactions(account: @card, cursor: "card-page", window: window)
    cash_page = @adapter.fetch_transactions(account: @cash, window: window)
    assert card_page.complete?
    refute cash_page.complete?
    assert_equal "delta", card_page.mode
    assert_equal "posted_at_start", card_page.coverage["server_filter"]
    refute card_page.coverage.key?("end")
    assert_equal window["end"], card_page.coverage["requested_end"]
  end

  test "malformed money ownership dates and inventory cursors fail safely" do
    [ nil, { amount: nil }, { amount: 0.25, currency: "USD" }, { amount: "NaN", currency: "USD" }, { amount: "12.5", currency: "USD" } ].each do |amount|
      error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(amount: amount), account: @card) }
      assert_equal "Invalid Brex transaction", error.message
      assert_nil error.cause
    end
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(account_id: "other-account"), account: @cash) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(posted_at_date: "private-invalid-date"), account: @card) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_account(account_snapshot(current_balance: nil)) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.list_accounts(cursor: "private-bad-cursor") }
  end

  test "missing currency retains legacy USD conversion and account currency fallback" do
    record = @adapter.normalize_transaction(transaction(amount: { amount: 1234 }), account: @card)
    assert_equal BigDecimal("12.34"), record[:amount]
    assert_equal "USD", record[:currency]
  end

  test "builder uses the pure injected credential and settings contract" do
    Provider::Brex.expects(:new).with("private-token", base_url: "https://api-staging.brex.com").returns(@client)
    adapter = Provider::AccountData::Brex.build(
      credentials: { "token" => "private-token" }, settings: { "base_url" => "https://api-staging.brex.com" }, context: { timezone: "UTC" }
    )
    assert_instance_of Provider::AccountData::Brex, adapter
    refute_includes adapter.inspect, "private-token"
  end

  private
    def transaction(**overrides)
      {
        id: "transaction-1", description: "Office supplies", type: "CARD_EXPENSE",
        amount: { amount: 1234, currency: "USD" }, posted_at_date: "2026-01-02", initiated_at_date: "2026-01-01",
        merchant: { raw_descriptor: "ACME INC" }
      }.merge(overrides)
    end

    def account_snapshot(**overrides)
      {
        id: "cash-1", name: "Operating", account_kind: "cash", status: "ACTIVE",
        current_balance: { amount: 12345, currency: "USD" }, available_balance: { amount: 100_000, currency: "USD" },
        account_limit: { amount: 250_000, currency: "USD" }
      }.merge(overrides)
    end
end
