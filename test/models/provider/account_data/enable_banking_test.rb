require "test_helper"
require "ostruct"

class Provider::AccountData::EnableBankingTest < ActiveSupport::TestCase
  setup do
    @client = mock("Enable Banking transport")
    @authorization = { id: "grant-1", status: "active", expires_at: "2026-12-01T00:00:00Z",
      credentials: { session_id: "private-session", last_psu_ip: "192.0.2.4" }, institution_metadata: { name: "Test Bank" },
      metadata: { grant_settings: { aspsp_required_psu_headers: [ "Psu-Ip-Address" ] } } }
    @adapter = build_adapter
    @account = @adapter.normalize_account(account_data)
  end

  test "valid transaction posting arguments retain legacy semantics" do
    raw = transaction(remittance_information: [ "Invoice 123", "Thank you" ], note: "Memo",
      exchange_rate: { exchange_rate: "1.02", unit_currency: "USD", instructed_amount: { amount: "12.40" } })
    linked = OpenStruct.new(family: OpenStruct.new(timezone: "America/Los_Angeles"), currency: "EUR")
    legacy = OpenStruct.new(current_account: linked, id: "legacy-account")
    importer = mock("legacy ledger boundary")
    merchant = OpenStruct.new(name: "Shop")
    importer.expects(:find_or_create_merchant).with(provider_merchant_id: "enable_banking_merchant_#{Digest::MD5.hexdigest('shop')}",
      name: "Shop", source: "enable_banking").returns(merchant)
    imported = nil
    importer.expects(:import_transaction).with { |**attrs| imported = attrs }.returns(:entry)
    # Compare normalization only. Public posting admission is covered with real
    # persisted source/account fixtures in EnableBankingItem::AdmissionTest.
    processor = EnableBankingEntry::Processor.allocate
    processor.instance_variable_set(:@enable_banking_transaction, raw)
    processor.instance_variable_set(:@enable_banking_account, legacy)
    processor.instance_variable_set(:@import_adapter, importer)
    processor.instance_variable_set(:@known_merchant_names, [])
    assert_equal :entry, processor.send(:process_admitted)
    normalized = @adapter.normalize_transaction(raw, account: @account)
    %i[external_id amount currency name date].each { |key| assert_equal imported[key], normalized[key] }
    assert_equal imported[:notes], normalized[:metadata][:notes]
    assert_equal imported[:extra][:enable_banking], normalized[:metadata][:extra][:enable_banking].except(:pending)
    assert_equal merchant.name, normalized[:metadata][:merchant][:name]
  end

  test "amount direction timezone and exact precision are explicit" do
    row = @adapter.normalize_transaction(transaction(credit_debit_indicator: "CRDT", debtor: { name: "Employer" },
      booking_date: "2026-09-14T01:30:00Z", transaction_amount: { amount: "-0.123456789012345678", currency: "EUR" }), account: @account)
    assert_equal BigDecimal("-0.123456789012345678"), row[:amount]
    assert_equal "Employer", row[:name]
    assert_equal Date.new(2026, 9, 13), row[:date]
    assert_equal "EUR", row[:currency]
  end

  test "ID-less transaction and remittance order retain historical fingerprints" do
    raw = transaction(transaction_id: nil, entry_reference: nil, remittance_information: [ "B", nil, "A" ])
    normalized = @adapter.normalize_transaction(raw, account: @account)
    assert_equal EnableBankingEntry::Processor.compute_external_id(raw), normalized[:external_id]
    assert_equal normalized[:external_id], @adapter.normalize_transaction(raw.merge(remittance_information: [ "A", "B" ]), account: @account)[:external_id]
  end

  test "legacy monetary floats are explicit and fingerprinted before conversion" do
    raw = transaction(transaction_id: nil, entry_reference: nil, transaction_amount: { amount: 12.34, currency: "EUR" })
    normalized = @adapter.normalize_legacy_transaction(raw, account: @account)
    assert_equal EnableBankingEntry::Processor.compute_external_id(raw), normalized[:external_id]
    assert_equal BigDecimal("12.34"), normalized[:amount]
    assert_instance_of Float, raw[:transaction_amount][:amount]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
  end

  test "malformed money dates and identity are quarantined instead of becoming zero" do
    [ nil, "invalid", Float::INFINITY, 1.5 ].each do |amount|
      assert_raises(Provider::AccountData::InvalidResponse) do
        @adapter.normalize_transaction(transaction(transaction_amount: { amount: amount, currency: "EUR" }), account: @account)
      end
    end
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(transaction(booking_date: "2026-02-30"), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction({}, account: @account) }
  end

  test "wallet and processor cleanup preserve raw notes and known merchant matching" do
    adapter = build_adapter(known_merchant_names: [ "Apple", "Billa", "Billa Plus" ])
    row = adapter.normalize_transaction(transaction(creditor: { name: "CARD-1234" },
      remittance_information: [ "POS 45,13 AT D6 31.07. 10:27", "Apple pay: BILLA PLUS DANKT" ]), account: @account)
    assert_equal "Billa Plus", row[:name]
    assert_equal "Billa Plus", row[:metadata][:merchant][:name]
    assert_includes row[:metadata][:notes], "Apple pay: BILLA PLUS DANKT"
    processor = adapter.normalize_transaction(transaction(creditor: { name: "CARD-42" }, remittance_information: "SQ * Corner Cafe"), account: @account)
    assert_equal "Corner Cafe", processor[:name]
  end

  test "unknown noisy remittance does not invent a merchant" do
    row = @adapter.normalize_transaction(transaction(creditor: nil, remittance_information: "POS 12,34 new merchant"), account: @account)
    assert_nil row[:metadata][:merchant]
    assert_equal "POS 12,34 new merchant", row[:name]
  end

  test "settled transaction retains entry reference pending identity" do
    row = @adapter.normalize_transaction(transaction(transaction_id: "settled-id", entry_reference: "pending-ref"), account: @account)
    assert_equal "enable_banking_settled-id", row[:external_id]
    assert_equal "enable_banking_pending-ref", row[:pending_external_id]
    assert_equal false, row[:pending]
    assert_equal false, row[:metadata][:extra][:enable_banking][:pending]
  end

  test "rotated consent account UID matches an authorized stable alias" do
    old = { id: "external-1", external_id: "stable-old-hash", name: "Saved account", currency: "EUR", authorization_ids: [ "grant-1" ],
      metadata: {}, sensitive_details: { identification_hashes: [ "stable-old-hash", "stable-new-hash" ] } }
    row = build_adapter(external_accounts: [ old ]).normalize_account(account_data(uid: "rotated-api-uid", identification_hash: "stable-new-hash"))
    assert_equal "stable-old-hash", row[:external_id]
    assert_equal "rotated-api-uid", row[:sensitive_details][:api_account_id]
    assert_equal "grant-1", row[:metadata][:authorization_id]
    refute_includes row[:metadata].to_s, "private-session"
    refute_includes row[:metadata].to_s, "DE123456789"
  end

  test "same alias outside authorization membership cannot claim an existing account" do
    old = { external_id: "stable-old-hash", authorization_ids: [ "other-grant" ], metadata: {},
      sensitive_details: { identification_hashes: [ "stable-hash" ] } }
    row = build_adapter(external_accounts: [ old ]).normalize_account(account_data)
    assert_equal "stable-hash", row[:external_id]
  end

  test "ambiguous aliases fail instead of silently relinking financial accounts" do
    old = { external_id: "old", authorization_ids: [ "grant-1" ], metadata: {}, sensitive_details: { identification_hashes: [ "stable-hash" ] } }
    assert_raises(Provider::AccountData::InvalidResponse) { build_adapter(external_accounts: [ old, old.merge(external_id: "other") ]).normalize_account(account_data) }
  end

  test "inventory hydrates UID strings and keeps raw responses in evidence" do
    session = { accounts: [ "api-uid" ], accounts_data: [ { uid: "api-uid", identification_hash: "stable-hash" } ], access: { valid_until: "2026-12-01T00:00:00Z" } }
    @client.expects(:get_ingestion_session).with(session_id: "private-session").returns(session)
    @client.expects(:get_ingestion_account_details).with(account_id: "api-uid", psu_headers: { "Psu-Ip-Address" => "192.0.2.4" }).returns(account_data)
    page = @adapter.list_accounts
    assert page.complete?
    assert_equal "stable-hash", page.records.first[:external_id]
    assert_equal false, page.records.first[:metadata][:balance_provided]
    assert_nil page.records.first[:balance]
    assert_equal session.deep_stringify_keys, page.evidence["session"]
    refute_includes page.inspect, "DE123456789"
  end

  test "session-level authorization failure is explicit and incomplete" do
    error = Provider::EnableBanking::EnableBankingError.new("request failed", :unauthorized)
    @client.expects(:get_ingestion_session).raises(error)
    page = @adapter.list_accounts
    refute page.complete?
    assert_nil page.next_cursor
    assert_equal "authorization_requires_update", page.warnings.first["code"]
    assert_equal "grant-1", page.warnings.first["authorization_id"]
  end

  test "account-level unauthorized does not classify the institution consent as expired" do
    @client.expects(:get_ingestion_session).returns(accounts: [ "api-uid" ])
    @client.expects(:get_ingestion_account_details).raises(Provider::EnableBanking::EnableBankingError.new("failed", :unauthorized))
    page = @adapter.list_accounts
    refute page.complete?
    assert_equal "authorization_inventory_unavailable", page.warnings.first["code"]
  end

  test "one unavailable consent does not hide other institution inventories" do
    grants = [ @authorization.merge(status: "requires_update"), @authorization.merge(id: "grant-2") ]
    adapter = build_adapter(authorizations: grants)
    first = adapter.list_accounts
    assert first.next_cursor
    @client.expects(:get_ingestion_session).returns(accounts: [])
    second = build_adapter(authorizations: grants).list_accounts(cursor: first.next_cursor)
    refute second.complete?
    assert_nil second.next_cursor
  end

  test "booked ledger balance wins over available including overdraft" do
    raw = { balances: [ { balance_type: "closingAvailable", balance_amount: { amount: "1000", currency: "EUR" } },
      { balance_type: "CLBD", balance_amount: { amount: "50.12", currency: "EUR" }, credit_debit_indicator: "DBIT" } ] }
    @client.expects(:get_ingestion_account_balances).with(account_id: "api-uid", psu_headers: { "Psu-Ip-Address" => "192.0.2.4" }).returns(raw)
    page = @adapter.fetch_balance(account: @account)
    assert_equal BigDecimal("-50.12"), page.records.first[:balance]
    assert_equal raw, page.evidence["response"]
  end

  test "empty balance preserves unknown instead of manufacturing zero" do
    page = @adapter.normalize_balance({ balances: [] }, account: @account)
    assert_nil page.records.first[:balance]
    assert_equal "balance_unavailable", page.warnings.first["code"]
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_balance({}, account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_balance({ balances: [ { amount: "not-money" } ] }, account: @account) }
  end

  test "migrated credit interpretation is an explicit writer policy" do
    old = { external_id: "stable-hash", authorization_ids: [ "grant-1" ], metadata: { source_details:
      Provider::AccountData::MigrationValue.encode({ identity: {}, settings: { treat_balance_as_available_credit: true }, attributes: { credit_limit: BigDecimal("1000") } }) } }
    row = build_adapter(external_accounts: [ old ]).normalize_account(account_data)
    assert_equal "available_credit", row[:metadata][:balance_policy][:credit_card_mode]
    assert_equal "1000.0", row[:metadata][:balance_policy][:credit_limit]
    assert_equal "absolute", row[:metadata][:balance_policy][:debt_transform]
    assert_equal true, row[:metadata][:balance_policy][:current_anchor]
  end

  test "BOOK then PDNG pages resume with a new adapter and suppress settled duplicates" do
    booked = transaction(transaction_id: "settled", entry_reference: "same-ref")
    @client.expects(:get_ingestion_transactions_page).with do |**args|
      args[:transaction_status] == "BOOK" && args[:continuation_key].nil?
    end.returns(page_result([ booked ]))
    first = @adapter.fetch_transactions(account: @account, window: window)
    refute first.complete?
    @client.expects(:get_ingestion_transactions_page).with do |**args|
      args[:transaction_status] == "PDNG" && args[:continuation_key].nil?
    end.returns(page_result([ transaction(transaction_id: nil, entry_reference: "same-ref"), transaction(transaction_id: "held", entry_reference: "held-ref") ]))
    last = build_adapter.fetch_transactions(account: @account, cursor: first.next_cursor, window: window)
    assert last.complete?
    assert_equal [ "enable_banking_held" ], last.records.map { |record| record[:external_id] }
    assert last.records.first[:pending]
    assert_equal "delta", last.mode
    assert_equal false, last.coverage["pending_absence_authoritative"]
  end

  test "different transaction IDs survive content dedup and duplicate references do not" do
    rows = [ transaction(transaction_id: nil, entry_reference: "one"), transaction(transaction_id: nil, entry_reference: "two"),
      transaction(transaction_id: "different-transaction", entry_reference: "three") ]
    @client.expects(:get_ingestion_transactions_page).returns(page_result(rows))
    page = build_adapter(include_pending: false).fetch_transactions(account: @account, window: window)
    assert_equal [ "enable_banking_one", "enable_banking_different-transaction" ], page.records.map { |record| record[:external_id] }
    assert_equal rows, page.evidence["response"][:transactions]
  end

  test "pending preference also filters banks ignoring BOOK status" do
    @client.expects(:get_ingestion_transactions_page).once.returns(page_result([ transaction(status: "PDNG") ]))
    page = build_adapter(include_pending: false).fetch_transactions(account: @account, window: window)
    assert page.complete?
    assert_empty page.records
  end

  test "unsupported pending is a warning while failed BOOK continuation cannot advance" do
    @client.expects(:get_ingestion_transactions_page).returns(page_result([]))
    first = @adapter.fetch_transactions(account: @account, window: window)
    @client.expects(:get_ingestion_transactions_page).raises(Provider::EnableBanking::EnableBankingError.new("unsupported", :bad_request))
    page = @adapter.fetch_transactions(account: @account, cursor: first.next_cursor)
    assert page.complete?
    assert_equal "pending_unsupported", page.warnings.first["code"]

    @client.expects(:get_ingestion_transactions_page).returns(page_result([], next_cursor: "next"))
    partial = @adapter.fetch_transactions(account: @account, window: window)
    @client.expects(:get_ingestion_transactions_page).raises(Provider::EnableBanking::EnableBankingError.new("invalid continuation", :validation_error))
    assert_raises(Provider::EnableBanking::EnableBankingError) { @adapter.fetch_transactions(account: @account, cursor: partial.next_cursor) }
  end

  test "continuation reuse across accounts and repeated provider cursors are rejected" do
    @client.expects(:get_ingestion_transactions_page).returns(page_result([], next_cursor: "same"))
    first = @adapter.fetch_transactions(account: @account, window: window)
    other = Ingestion::Record.account(**@account.attributes.merge(external_id: "other-account"))
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_transactions(account: other, cursor: first.next_cursor) }
    @client.expects(:get_ingestion_transactions_page).returns(page_result([], next_cursor: "same"))
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_transactions(account: @account, cursor: first.next_cursor) }
  end

  test "application credentials never borrow institution session credentials" do
    Provider::EnableBanking.expects(:new).with(application_id: "application", client_certificate: "private-key").returns(@client)
    adapter = Provider::AccountData::EnableBanking.build(credentials: { application_id: "application", client_certificate: "private-key" },
      settings: { country_code: "DE" }, context: { timezone: "UTC", observed_at: Time.utc(2026, 9, 14), authorizations: [ @authorization ],
        external_accounts: [], known_merchant_names: [], pending_preference: false })
    refute Provider::AccountData::EnableBanking.native_ready?
    refute_includes adapter.inspect, "private-key"
    refute_includes adapter.inspect, "private-session"
  end

  private
    def build_adapter(**options)
      Provider::AccountData::EnableBanking.new(**{
        client: @client, timezone: "America/Los_Angeles", authorizations: [ @authorization ], external_accounts: [],
        known_merchant_names: [], observed_at: Time.utc(2026, 9, 14, 12), include_pending: true
      }.merge(options))
    end

    def account_data(**attributes)
      { uid: "api-uid", identification_hash: "stable-hash", name: "Checking", currency: "EUR", account_id: { iban: "DE123456789" } }.merge(attributes)
    end

    def transaction(**attributes)
      { transaction_id: "tx-1", entry_reference: "ref-1", booking_date: "2026-09-13", credit_debit_indicator: "DBIT", status: "BOOK",
        transaction_amount: { amount: "12.34", currency: "EUR" }, creditor: { name: "Shop" } }.merge(attributes)
    end

    def page_result(rows, next_cursor: nil)
      { items: rows, next_cursor: next_cursor, date_from: Date.new(2026, 9, 1), date_to: Date.new(2026, 9, 14), evidence: { transactions: rows } }
    end

    def window
      { start: "2026-09-01T07:00:00Z", end: "2026-09-14T12:00:00Z" }
    end
end
