require "test_helper"

class Provider::AccountData::WiseTest < ActiveSupport::TestCase
  setup do
    @client = mock("Wise transport")
    @adapter = Provider::AccountData::Wise.new(client: @client, profile_id: "profile_1", timezone: "Europe/Berlin")
    @account = Ingestion::Record.account(external_id: "balance_1", name: "Wise EUR", currency: "EUR", account_type: "STANDARD")
    @jar = Ingestion::Record.account(external_id: "jar_1", name: "Trip", currency: "EUR", account_type: "SAVINGS")
    @window = { start: "2026-01-01T00:00:00Z", end: "2026-01-20T00:00:00Z" }
  end

  test "keeps migration activation gated after the statement fallback protocol" do
    refute Provider::AccountData::Wise.native_ready?
  end

  test "builds sandbox transport with the SCA key and explicit profile" do
    Provider::Wise.expects(:new).with("token", base_url: Provider::Wise::SANDBOX_BASE_URL, sca_private_key: "private-key").returns(@client)
    adapter = Provider::AccountData::Wise.build(credentials: { token: "token", sca_private_key: "private-key" }, settings: { profile_id: 123 },
      context: { environment: "sandbox", timezone: "Europe/Berlin", wise_account_history: {
        "format" => Provider::AccountData::Wise::AccountHistory::FORMAT, "profile_id" => "123", "accounts" => {}
      } })

    assert_instance_of Provider::AccountData::Wise, adapter
  end

  test "JAR balances use total worth and preserve reserved amounts and recipient identity" do
    account = @adapter.normalize_account({ id: 10, type: "SAVINGS", name: "Trip", amount: { value: "10", currency: "EUR" },
      totalWorth: { value: "12.123456789012345678" }, reservedAmount: { value: "2" } }, identifiers: { recipient_id: 55 })

    assert_equal BigDecimal("12.123456789012345678"), account[:balance]
    assert_equal BigDecimal("2"), account[:reserved_balance]
    assert_equal 55, account[:sensitive_details][:recipient_id]
    assert_equal "SAVINGS", account[:account_type]
  end

  test "statements retain signed net movement separate fees names and IDs" do
    main, fee = @adapter.normalize_statement(statement, account: @account)

    assert_equal "wise_statement_ref-1", main[:external_id]
    assert_equal BigDecimal("7.72"), main[:amount]
    assert_equal "Payment INV-123", main[:name]
    assert_equal "wise_statement_ref-1_fee", fee[:external_id]
    assert_equal BigDecimal("0.04"), fee[:amount]
    assert_equal "INV-123", main[:metadata][:extra][:wise][:payment_reference]
    assert_equal Date.new(2026, 1, 15), main[:date]
  end

  test "foreign-denominated statement fees are never mixed into the movement currency" do
    records = @adapter.normalize_statement(statement(totalFees: { value: "1", currency: "USD" }), account: @account)

    assert_equal 1, records.size
    assert_equal BigDecimal("7.76"), records.first[:amount]
  end

  test "statement fallback digest includes the legacy marker and scalar numeric representation" do
    raw = statement(referenceNumber: nil, id: nil, amount: { value: BigDecimal("-7.76"), currency: "EUR" })
    legacy = raw.deep_stringify_keys.merge("wise_statement" => true)
    legacy["amount"]["value"] = -7.76
    expected = Digest::SHA256.hexdigest(legacy.to_json)[0, 24]

    assert_equal "wise_statement_#{expected}", @adapter.normalize_statement(raw, account: @account).first[:external_id]
  end

  test "legacy transfer direction fee and custom FX rate remain unchanged" do
    account = Ingestion::Record.account(external_id: "balance_1", name: "Wise EUR", currency: "EUR", sensitive_details: { recipient_id: 99 })
    main, fee = @adapter.normalize_transfer(transfer(targetAccount: 8), account: account)
    incoming = @adapter.normalize_transfer(transfer(targetAccount: 99, targetCurrency: "USD", targetValue: "120", rate: "1.2"), account: account).first

    assert_equal "wise_transfer_10", main[:external_id]
    assert_equal BigDecimal("100"), main[:amount]
    assert_equal "wise_fee_10", fee[:external_id]
    assert_equal BigDecimal("1"), fee[:amount]
    assert_equal BigDecimal("-120"), incoming[:amount]
    # The legacy importer pairs targetValue with sourceCurrency and the custom
    # exchange rate; migration must not reinterpret already-ingested movements.
    assert_equal "EUR", incoming[:currency]
    assert_equal BigDecimal("1.2"), incoming[:metadata][:extra][:exchange_rate]
    assert_equal "incoming", incoming[:metadata][:extra][:wise][:direction]
  end

  test "interbalance activity preserves legacy external ID roles and actual pair direction" do
    into_jar = activity(type: "INTERBALANCE", title: "To <strong>Trip</strong>", primaryAmount: "1,000 EUR")
    jar = @adapter.normalize_activity(into_jar, account: @jar)
    standard = @adapter.normalize_activity(into_jar, account: @account)
    withdrawal = @adapter.normalize_activity(into_jar.merge(title: "From <strong>Trip</strong>"), account: @jar)

    assert_equal "wise_interbalance_resource_1_inflow", jar[:external_id]
    assert_equal "wise_interbalance_resource_1_outflow", standard[:external_id]
    assert_equal BigDecimal("-1000"), jar[:amount]
    assert_equal BigDecimal("1000"), standard[:amount]
    assert_equal "confirmed", jar[:metadata][:transfer_pair][:status]
    assert_equal "outflow", withdrawal[:metadata][:transfer_pair][:role]
    assert_equal "wise_interbalance_resource_1_inflow", withdrawal[:external_id]
  end

  test "cashback and asset fees preserve signs and provider calendar date" do
    cashback = @adapter.normalize_activity(activity(createdOn: "2026-01-14T23:30:00Z"), account: @jar)
    fee = @adapter.normalize_activity(activity(type: "BALANCE_ASSET_FEE"), account: @jar)

    assert_equal BigDecimal("-1.12"), cashback[:amount]
    assert_equal BigDecimal("1.12"), fee[:amount]
    assert_equal Date.new(2026, 1, 14), cashback[:date]
    assert_equal "wise_activity_activity_1", cashback[:external_id]
  end

  test "successful empty statement responses continue to activities without transfer fallback" do
    @client.expects(:get_balance_statement_page).returns(items: [], next_cursor: nil)
    @client.expects(:get_transfers_page).never
    first = @adapter.fetch_transactions(account: @account, window: @window)
    refute first.complete?
    @client.expects(:get_activities_page).with("profile_1", cursor: nil).returns(items: [], next_cursor: nil)

    last = @adapter.fetch_transactions(account: @account, window: @window, cursor: first.next_cursor)

    assert last.complete?
    assert_empty last.records
  end

  test "statement permission failures cannot invent a connection-wide fallback authorization" do
    account = Ingestion::Record.account(**@account.attributes.merge(metadata: { transaction_policy: { statement_fallback_authorized: true } }))
    @client.expects(:get_balance_statement_page).raises(Provider::Wise::WiseError.new("Forbidden", :access_forbidden))

    assert_raises(Provider::Wise::WiseError) { @adapter.fetch_transactions(account: account, window: @window) }
  end

  test "authorized fallback remains incomplete until transfer and activity pages finish" do
    account = Ingestion::Record.account(external_id: "balance_1", name: "Wise EUR", currency: "EUR",
      metadata: { "runtime_external_account_id" => "external-1" })
    @client.expects(:get_balance_statement_page).raises(Provider::Wise::WiseError.new("Forbidden", :access_forbidden))
    probe = @adapter.probe_statement(account: account, window: @window)
    @adapter.bind_statement_barrier!(probes: { "balance_1" => { "batch_id" => "probe-1", "page" => probe } },
      windows: { "external-1" => @window }, header_id: "header-1", fingerprint: "fingerprint")
    first = @adapter.fetch_transactions(account: account, window: @window)
    @client.expects(:get_transfers_page).with("profile_1", cursor: nil).returns(items: [], next_cursor: "100")
    second = @adapter.fetch_transactions(account: account, window: @window, cursor: first.next_cursor)
    @client.expects(:get_transfers_page).with("profile_1", cursor: "100").returns(items: [], next_cursor: nil)
    third = @adapter.fetch_transactions(account: account, window: @window, cursor: second.next_cursor)
    @client.expects(:get_activities_page).with("profile_1", cursor: nil).returns(items: [], next_cursor: "activities-2")
    fourth = @adapter.fetch_transactions(account: account, window: @window, cursor: third.next_cursor)
    @client.expects(:get_activities_page).with("profile_1", cursor: "activities-2").returns(items: [], next_cursor: nil)
    last = @adapter.fetch_transactions(account: account, window: @window, cursor: fourth.next_cursor)

    assert_equal "statement_unavailable_transfer_fallback", first.warnings.first["code"]
    [ first, second, third, fourth ].each { |page| refute page.complete? }
    assert last.complete?
    assert_equal false, last.coverage["history_complete"]
  end

  test "statements use bounded contiguous windows and keep response evidence outside normalized metadata" do
    window = { start: "2026-01-01T00:00:00Z", end: "2026-03-15T00:00:00Z" }
    raw_response = { "transactions" => [ statement ], "accountHolder" => "private-holder" }
    @client.expects(:get_balance_statement_page).with("profile_1", "balance_1", currency: "EUR",
      interval_start: Time.utc(2026, 1, 1), interval_end: Time.utc(2026, 1, 31))
      .returns(items: [ statement ], next_cursor: nil, evidence: raw_response)
    first = @adapter.fetch_transactions(account: @account, window: window)
    @client.expects(:get_balance_statement_page).with("profile_1", "balance_1", currency: "EUR",
      interval_start: Time.utc(2026, 1, 31), interval_end: Time.utc(2026, 3, 2))
      .returns(items: [], next_cursor: nil)
    second = @adapter.fetch_transactions(account: @account, window: window, cursor: first.next_cursor)

    refute first.complete?
    refute second.complete?
    assert_equal raw_response, first.evidence["response"]
    refute_includes first.records.first[:metadata].inspect, "private-holder"
    refute_includes first.inspect, "private-holder"
  end

  test "migrated cutoff suppresses only outgoing overlap while keeping incoming payments" do
    account = Ingestion::Record.account(external_id: "balance_1", name: "Wise EUR", currency: "EUR",
      metadata: { transaction_policy: { legacy_transfer_cutoff: "2026-01-01", has_statement_history: true } })
    @client.expects(:get_balance_statement_page).returns(items: [ statement, statement(referenceNumber: "credit", amount: { value: "20", currency: "EUR" }, totalFees: nil) ], next_cursor: nil)

    page = @adapter.fetch_transactions(account: account, window: @window)

    assert_equal [ "wise_statement_credit" ], page.records.map { |record| record[:external_id] }
    assert_equal BigDecimal("-20"), page.records.first[:amount]
  end

  test "rejects invalid money dates activities and cursor shapes without exposing raw values" do
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_statement(statement(amount: { value: 1.25, currency: "EUR" }), account: @account) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transfer(transfer(created: nil), account: @account) }
    error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_activity(activity(primaryAmount: "private-invalid-amount"), account: @jar) }
    assert_nil error.cause
    refute_includes error.message, "private-invalid-amount"
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_transactions(account: @account, window: @window, cursor: "invalid") }
  end

  private
    def statement(**overrides)
      { type: "DEBIT", date: "2026-01-15T10:00:00Z", amount: { value: "-7.76", currency: "EUR" },
        totalFees: { value: "0.04", currency: "EUR" }, details: { description: "Payment", paymentReference: "INV-123" }, referenceNumber: "ref-1" }.merge(overrides)
    end

    def transfer(**overrides)
      { id: 10, sourceValue: "100", targetValue: "99", sourceCurrency: "EUR", targetCurrency: "EUR",
        targetAccount: 8, status: "outgoing_payment_sent", created: "2026-01-15T10:00:00Z" }.merge(overrides)
    end

    def activity(**overrides)
      { id: "activity_1", type: "BALANCE_CASHBACK", resource: { type: "BALANCE_CASHBACK", id: "resource_1" },
        title: "Cashback", primaryAmount: "<positive>+ 1.12 EUR</positive>", createdOn: "2026-01-15T10:00:00Z" }.merge(overrides)
    end
end
