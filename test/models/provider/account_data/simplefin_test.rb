require "test_helper"
require "ostruct"

class Provider::AccountData::SimplefinTest < ActiveSupport::TestCase
  setup do
    @client = mock("SimpleFIN transport")
    @access_url = "https://private-user:private-password@bridge.example/access"
    @adapter = build_adapter
    @account = account_record
  end

  test "transactions retain legacy IDs signs dates names merchants notes and FX enrichment" do
    raw = transaction(currency: " eur ", payee: "  Bakery  ", description: "Lunch", memo: " A note ",
      extra: { "category" => "food", "check_number" => nil })
    linked = OpenStruct.new(currency: "USD")
    legacy = OpenStruct.new(current_account: linked, account_type: "checking")
    importer = mock("legacy ledger boundary")
    merchant = OpenStruct.new(name: "Bakery")
    Account::ProviderImportAdapter.expects(:new).with(linked).returns(importer)
    importer.expects(:find_or_create_merchant).with(
      provider_merchant_id: "simplefin_#{Digest::MD5.hexdigest('bakery')}", name: "Bakery", source: "simplefin"
    ).returns(merchant)
    imported = nil
    importer.expects(:import_transaction).with { |**attributes| imported = attributes }.returns(:entry)

    assert_equal :entry, SimplefinEntry::Processor.new(raw, simplefin_account: legacy).process
    normalized = @adapter.normalize_transaction(raw, account: @account)

    %i[external_id amount date name currency].each { |key| assert_equal imported[key], normalized[key] }
    assert_equal "simplefin", imported[:source]
    assert_equal imported[:extra], normalized[:metadata][:extra]
    assert_equal imported[:notes], normalized[:metadata][:notes]
    assert_equal merchant.name, normalized[:metadata][:merchant][:name]
    assert_equal "EUR", normalized[:metadata][:extra]["simplefin"]["fx_from"]
    assert_equal "2026-01-14", normalized[:metadata][:extra]["simplefin"]["fx_date"]
  end

  test "pending classification exactly preserves explicit boolean casting and epoch inference" do
    variants = [
      { pending: true }, { pending: "true" }, { pending: "0" }, { pending: false },
      { pending: nil, posted: 0, transacted_at: 1_768_348_800 },
      { pending: nil, posted: "0", transacted_at: "1768348800" },
      { pending: nil, posted: nil }, { pending: nil, posted: "unavailable" }
    ]
    variants.each do |overrides|
      raw = transaction(**overrides)
      normalized = @adapter.normalize_transaction(raw, account: @account)
      assert_equal SimplefinEntry::Processor.pending?(raw), normalized[:pending]
      assert_equal normalized[:pending], normalized[:metadata][:extra]["simplefin"]["pending"]
    end
    disabled = build_adapter(include_pending: false)
    assert_nil disabled.normalize_transaction(transaction(pending: true), account: @account)
    assert_not_nil disabled.normalize_transaction(transaction(pending: false), account: @account)
  end

  test "transaction dates preserve provider UTC epochs and statement dates for credit cards and loans" do
    %w[credit_card credit loan mortgage].each do |type|
      account = account_record(account_type: type)
      assert_equal Date.new(2026, 1, 14), @adapter.normalize_transaction(transaction, account: account)[:date]
    end
    assert_equal Date.new(2026, 1, 15), @adapter.normalize_transaction(transaction, account: @account)[:date]
    epoch = Time.utc(2026, 1, 15, 0, 10).to_i
    assert_equal Date.new(2026, 1, 15), @adapter.normalize_transaction(transaction(posted: epoch), account: @account)[:date]
    assert_equal Date.new(2026, 1, 14), @adapter.normalize_transaction(transaction(posted: 0), account: @account)[:date]
  end

  test "malformed monetary data cannot become zero and real zero remains distinct from missing balance" do
    precise = @adapter.normalize_transaction(transaction(amount: "-0.123456789012345678"), account: @account)
    assert_equal BigDecimal("0.123456789012345678"), precise[:amount]
    assert_equal BigDecimal("-123"), @adapter.normalize_transaction(transaction(amount: "123"), account: @account)[:amount]
    assert_equal BigDecimal("-1.25"), @adapter.normalize_legacy_transaction(transaction(amount: 1.25), account: @account)[:amount]
    [ nil, "invalid", "Infinity", 1.25, Float::NAN, {} ].each do |amount|
      error = assert_raises(Provider::AccountData::InvalidResponse) do
        @adapter.normalize_transaction(transaction(amount: amount), account: @account)
      end
      assert_nil error.cause
    end
    zero = @adapter.normalize_account(account_snapshot(balance: "0", "available-balance": "25"))
    missing = @adapter.normalize_account(account_snapshot(balance: nil, "available-balance": "25"))
    assert_equal BigDecimal("0"), zero[:balance]
    assert_nil missing[:balance]
    assert_equal BigDecimal("25"), missing[:available_balance]
    assert_equal "current_else_available", missing[:metadata][:balance_policy][:observed_balance]
  end

  test "accounts retain their own institutions and provider types without splitting credentials" do
    @client.expects(:get_accounts_snapshot).with(@access_url, start_date: nil, end_date: nil, pending: true)
      .returns(accounts: [ account_snapshot, account_snapshot(id: "second", org: { name: "Other Bank", domain: "other.example" }) ])

    page = @adapter.list_accounts

    assert page.complete?
    assert_equal %w[sf-account second], page.records.map { |record| record[:external_id] }
    assert_equal [ "Example Bank", "Other Bank" ], page.records.map { |record| record[:metadata][:institution].fetch("name") }
    assert_equal "checking", page.records.first[:account_type]
    assert_equal 2, page.evidence.fetch("response").fetch("accounts").length
    assert_equal "unknown", @adapter.normalize_account(account_snapshot(type: nil))[:account_type]
    assert_equal "USD", @adapter.normalize_account(account_snapshot(currency: "https://currencies.example/USD"))[:currency]
    refute_includes @adapter.inspect, "private-password"
  end

  test "partial institution failures preserve healthy accounts and cannot establish inventory completeness" do
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot ],
      errors: [ "Reauthenticate Private Bank using private-user", { code: "timeout", message: "Private server timed out" } ])

    page = @adapter.list_accounts

    assert_not page.complete?
    assert_nil page.next_cursor
    assert_equal 1, page.records.size
    assert_equal %w[institution_auth institution_network], page.warnings.map { |warning| warning.fetch("code") }
    refute_includes page.warnings.to_json, "Private"
    refute_includes page.warnings.to_json, "private-user"
    assert_includes page.evidence.fetch("response").fetch("errors").first, "private-user"
  end

  test "balance evidence binds the fixed classifier snapshot and retains the original response" do
    snapshot = { "schema_version" => 1, "family_id" => "family-1", "account_id" => "account-1",
      "external_account_id" => "external-1", "account_type" => "CreditCard", "as_of" => "2026-01-31T00:00:00Z",
      "entry_metrics" => { "charges_total" => BigDecimal("123.4567") } }
    adapter = build_adapter(policy_snapshots: { "sf-account" => snapshot })
    @client.expects(:get_accounts_snapshot).once.returns(accounts: [ account_snapshot(balance: "-123.4567") ])
    adapter.list_accounts

    page = adapter.fetch_balance(account: @account)
    restored = Ingestion::Codec.load(Ingestion::Codec.dump(page))

    assert page.complete?
    assert_equal BigDecimal("-123.4567"), page.records.sole[:balance]
    assert_equal snapshot, restored.evidence.fetch("balance_policy")
    assert_equal "-123.4567", restored.evidence.fetch("response").fetch("accounts").sole.fetch("balance")
    assert_equal %i[simplefin_balance_classification], Provider::AccountData::Simplefin.context_sources
  end

  test "missing balance observations retain empty values and cannot silently replace policy inputs" do
    snapshot = { "account_id" => "account-1" }
    @client.expects(:get_accounts_snapshot).returns(accounts: [])
    page = build_adapter(policy_snapshots: { "sf-account" => snapshot }).fetch_balance(account: @account)
    assert_not page.complete?
    assert_nil page.records.sole[:balance]
    assert_equal false, page.records.sole[:metadata][:balance_provided]
    assert_equal snapshot, page.evidence.fetch("balance_policy")

    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot ])
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_balance(account: @account) }
  end

  test "missing malformed and duplicate records never masquerade as a complete empty inventory" do
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot, account_snapshot, nil, account_snapshot(id: "valid") ])
    page = @adapter.list_accounts
    assert_not page.complete?
    assert_equal [ "valid" ], page.records.map { |record| record[:external_id] }

    [ nil, {}, { accounts: nil }, { accounts: [], errors: "bad envelope" } ].each do |envelope|
      adapter = build_adapter
      @client.expects(:get_accounts_snapshot).returns(envelope)
      assert_raises(Provider::AccountData::InvalidResponse) { adapter.list_accounts }
    end
  end

  test "complete unwindowed empty inventory differs from global provider failure" do
    @client.expects(:get_accounts_snapshot).returns(accounts: [], errors: [])
    assert @adapter.list_accounts.complete?
    @client.expects(:get_accounts_snapshot).returns(accounts: [], errors: [ "Make fewer requests; private credential" ])
    error = assert_raises(Provider::Simplefin::SimplefinError) { build_adapter.list_accounts }
    assert_equal :rate_limited, error.error_type
    refute_includes error.message, "private credential"
    assert_nil error.cause
  end

  test "transaction windows advance backwards in sixty day requests with original scope preserved" do
    from = Time.utc(2025, 10, 1)
    through = Time.utc(2026, 1, 15)
    middle = through - Provider::AccountData::Simplefin::WINDOW_SECONDS
    @client.expects(:get_accounts_snapshot).with(@access_url, start_date: middle, end_date: through, pending: true)
      .returns(accounts: [ account_snapshot(transactions: [ transaction ]) ])
    @client.expects(:get_accounts_snapshot).with(@access_url, start_date: from, end_date: middle, pending: true)
      .returns(accounts: [ account_snapshot(transactions: []) ])
    window = { start: from.iso8601, end: through.iso8601 }

    first = @adapter.fetch_transactions(account: @account, window: window)
    second = @adapter.fetch_transactions(account: @account, window: window, cursor: first.next_cursor)

    assert_not first.complete?
    assert first.next_cursor.present?
    assert second.complete?
    assert_nil second.next_cursor
    assert_equal window[:start], first.coverage.fetch("start")
    assert_equal window[:end], second.coverage.fetch("end")
    assert_equal middle.iso8601, second.coverage.fetch("page_end")
    assert_equal false, second.coverage.fetch("pending_absence_authoritative")
  end

  test "continuation cursors cannot change account or requested window" do
    window = { start: Time.utc(2025, 10, 1).iso8601, end: Time.utc(2026, 1, 15).iso8601 }
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot(transactions: []) ])
    first = @adapter.fetch_transactions(account: @account, window: window)

    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.fetch_transactions(account: account_record(external_id: "other"), window: window, cursor: first.next_cursor)
    end
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.fetch_transactions(account: @account, window: window.merge(start: Time.utc(2025, 9, 1).iso8601), cursor: first.next_cursor)
    end
    assert_raises(Provider::AccountData::InvalidResponse) do
      @adapter.fetch_transactions(account: @account, window: window, cursor: "not-base64")
    end
  end

  test "one envelope is reused across accounts and partial rows never permit checkpoint advancement" do
    window = { start: Time.utc(2026, 1, 1).iso8601, end: Time.utc(2026, 1, 31).iso8601 }
    @client.expects(:get_accounts_snapshot).once.returns(accounts: [
      account_snapshot(transactions: [ transaction, transaction(id: "broken", amount: "unreadable") ]),
      account_snapshot(id: "second", transactions: [])
    ], errors: [ "One institution needs reauthentication" ])

    first = @adapter.fetch_transactions(account: @account, window: window)
    second = @adapter.fetch_transactions(account: account_record(external_id: "second"), window: window)

    assert_equal 1, first.records.size
    assert_not first.complete?
    assert_nil first.next_cursor
    assert_not second.complete?
    assert_empty second.records
    assert_includes first.warnings.map { |value| value.fetch("code") }, "invalid_transaction"
  end

  test "missing transaction arrays remain unknown while explicit empty arrays are complete" do
    window = { start: Time.utc(2026, 1, 1).iso8601, end: Time.utc(2026, 1, 31).iso8601 }
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot.except(:transactions) ])
    assert_not @adapter.fetch_transactions(account: @account, window: window).complete?
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot(transactions: []) ])
    assert build_adapter.fetch_transactions(account: @account, window: window).complete?
  end

  test "a window may omit dormant accounts only when a clean unwindowed inventory confirms them" do
    window = { start: Time.utc(2026, 1, 1).iso8601, end: Time.utc(2026, 1, 31).iso8601 }
    @client.expects(:get_accounts_snapshot).with(@access_url, start_date: nil, end_date: nil, pending: true)
      .returns(accounts: [ account_snapshot ])
    @adapter.list_accounts
    @client.expects(:get_accounts_snapshot).with(@access_url,
      start_date: Time.utc(2026, 1, 1), end_date: Time.utc(2026, 1, 31), pending: true).returns(accounts: [])

    result = @adapter.fetch_transactions(account: @account, window: window)

    assert result.complete?
    assert_empty result.records
  end

  test "duplicate transactions select posted observations using the legacy merge preference" do
    pending = transaction(posted: 0, transacted_at: 1_768_348_800, pending: true)
    posted = transaction(posted: 1_768_435_200, transacted_at: 1_768_348_800, pending: false)
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot(transactions: [ pending, posted, pending ]) ])

    result = @adapter.fetch_transactions(account: @account,
      window: { start: Time.utc(2026, 1, 1).iso8601, end: Time.utc(2026, 1, 31).iso8601 })

    assert result.complete?
    assert_equal 1, result.records.size
    assert_equal false, result.records.first[:pending]
    assert_equal "simplefin_tx-1", result.records.first[:external_id]
  end

  test "holdings retain ticker namespaces current observation date and per share cost basis" do
    data = holding(symbol: nil, description: "Employer Fund", shares: "100", market_value: "500", cost_basis: "100")
    record = @adapter.normalize_holding(data, account: @account)
    expected_symbol = "CUSTOM:EMPLOYER_FUND_#{Digest::MD5.hexdigest('Employer Fund')[0, 5].upcase}"

    assert_equal expected_symbol, record[:security][:ticker]
    assert_equal true, record[:security][:offline]
    assert_equal "simplefin_holding-1", record[:external_id]
    assert_equal Date.new(2026, 1, 31), record[:date]
    assert_equal BigDecimal("5"), record[:price]
    assert_equal BigDecimal("100"), record[:metadata][:cost_basis]
    assert_equal BigDecimal("500"), record[:amount]
    crypto = @adapter.normalize_holding(holding(symbol: "BTC"), account: @account)
    assert_equal "CRYPTO:BTC", crypto[:security][:ticker]
  end

  test "known total-basis institutions and explicit total fields divide without magnitude guesses" do
    data = holding(shares: "100", market_value: "500", cost_basis: "100")
    %w[Vanguard Fidelity Schwab].each do |institution|
      record = @adapter.normalize_holding(data, account: @account, institution: { name: institution })
      assert_equal BigDecimal("1"), record[:metadata][:cost_basis]
    end
    record = @adapter.normalize_holding(data.except(:cost_basis).merge(total_cost: "500"), account: @account)
    assert_equal BigDecimal("5"), record[:metadata][:cost_basis]
    value_only = @adapter.normalize_holding(holding(shares: "2", market_value: nil, value: "100", price: "8"), account: @account)
    assert_equal BigDecimal("16"), value_only[:amount]
    assert_equal BigDecimal("50"), value_only[:metadata][:cost_basis]
    assert_equal false, value_only[:metadata][:delete_future_holdings]
  end

  test "investment cash excludes noncash market values and retains money market settlement funds" do
    raw = account_snapshot(balance: "1000", holdings: [
      holding(symbol: "VTI", market_value: "1200"),
      holding(symbol: "VMFXX", market_value: "100"),
      holding(symbol: "OTHER", description: "Settlement Fund", market_value: "200")
    ])
    record = @adapter.normalize_account(raw)
    assert_equal BigDecimal("-200"), record[:cash_balance]
    assert_equal "simplefin_overpayment_v1", record[:metadata][:balance_policy][:credit_card]
    assert_equal "positive_available_balance", record[:metadata][:balance_policy][:available_credit]
    assert_nil @adapter.normalize_holding(holding(shares: "0", market_value: "0", price: "0"), account: @account)
    assert_not Provider::AccountData::Simplefin.native_ready?
  end

  test "holdings omission never means deletion or a complete snapshot" do
    @client.expects(:get_accounts_snapshot).returns(accounts: [ account_snapshot.except(:holdings) ])
    page = @adapter.fetch_holdings(account: @account)
    assert_not page.complete?
    assert_equal false, page.coverage.fetch("absence_authoritative")
  end

  test "versioned balance policy selects an exact UUID and namespace and rejects a sibling" do
    uuid = SecureRandom.uuid
    selected = { "account_id" => SecureRandom.uuid, "external_account_id" => uuid, "identity_namespace" => "institution:bank" }
    adapter = build_adapter(policy_snapshots: { version: 2, accounts: { uuid => selected } })
    account = account_record(metadata: { runtime_external_account_id: uuid, runtime_identity_namespace: "institution:bank" })
    @client.expects(:get_accounts_snapshot).once.returns(accounts: [ account_snapshot ])
    assert_equal selected, adapter.fetch_balance(account: account).evidence.fetch("balance_policy")
    sibling = account_record(metadata: { runtime_external_account_id: uuid, runtime_identity_namespace: "connection" })
    assert_raises(Provider::AccountData::InvalidResponse) { adapter.fetch_balance(account: sibling) }
    other = account_record(metadata: { runtime_external_account_id: SecureRandom.uuid, runtime_identity_namespace: "institution:bank" })
    assert_raises(Provider::AccountData::InvalidResponse) { adapter.fetch_balance(account: other) }
  end

  private
    def build_adapter(**attributes)
      Provider::AccountData::Simplefin.new(**{
        client: @client, access_url: @access_url, include_pending: true, observed_at: Time.utc(2026, 1, 31)
      }.merge(attributes))
    end

    def account_record(**attributes)
      Ingestion::Record.account(**{ external_id: "sf-account", name: "Checking", currency: "USD", account_type: "checking" }.merge(attributes))
    end

    def account_snapshot(**attributes)
      { id: "sf-account", name: "Checking", type: "checking", currency: "USD", balance: "1000.25",
        "available-balance": "990.25", "balance-date": 1_768_435_200,
        org: { name: "Example Bank", domain: "example.bank", "sfin-url": "https://bank.example/simplefin" },
        transactions: [], holdings: [] }.merge(attributes)
    end

    def transaction(**attributes)
      { id: "tx-1", amount: "-12.3456", currency: "USD", payee: "Bakery", description: "Lunch", memo: "Memo",
        posted: "2026-01-15", transacted_at: "2026-01-14", pending: false }.merge(attributes)
    end

    def holding(**attributes)
      { id: "holding-1", symbol: "VTI", description: "Total Market", shares: "2", market_value: "200", price: "100",
        currency: "USD", created: 1_577_836_800 }.merge(attributes)
    end
end
