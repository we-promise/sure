require "test_helper"

class Provider::AccountData::IbkrTest < ActiveSupport::TestCase
  setup do
    @client = mock("bounded Flex client")
    @observed_at = Time.utc(2026, 5, 9, 12)
    @xml = file_fixture("ibkr/flex_statement.xml").read
    @adapter = build_adapter(staged_xml: @xml)
    @account = @adapter.list_accounts.records.first
  end

  test "factory separates Flex credentials and remains gated" do
    Provider::IbkrFlex.expects(:new).with(query_id: "query", token: "secret").returns(@client)
    scope = Provider::AccountData::Ibkr::Export.scope(family_id: "family", provider_connection_id: "connection", sync_id: "sync",
      observed_at: @observed_at, timezone: "UTC")
    adapter = Provider::AccountData::Ibkr.build(credentials: { query_id: "query", token: "secret" }, settings: {},
      context: { timezone: "UTC", observed_at: @observed_at, current_time: @observed_at, ibkr_export: { scope: scope, export: nil } })
    assert_instance_of Provider::AccountData::Ibkr, adapter
    assert_equal %w[holdings activities], adapter.capabilities
    assert_not Provider::AccountData::Ibkr.native_ready?
    assert_not_includes adapter.inspect, "secret"
  end

  test "inventory retains both accounts and exact legacy balances from one immutable XML" do
    expected = IbkrItem::ReportParser.new(@xml).parse.fetch(:accounts)
    page = @adapter.list_accounts
    assert page.complete?
    assert_equal %w[U1234567 U7654321], page.records.map { |row| row[:external_id] }
    page.records.zip(expected).each do |record, old|
      assert_equal old[:currency], record[:currency]
      assert_equal old[:current_balance], record[:balance]
      assert_equal old[:cash_balance], record[:cash_balance]
      assert_equal old[:report_date], record[:balance_date]
    end
    assert_equal @xml, page.evidence["response_xml"]
    assert_equal Digest::SHA256.hexdigest(@xml), @account[:metadata][:statement_sha256]
    assert_equal BigDecimal("3351"), Ingestion::Codec.load(Ingestion::Codec.dump(page)).records.first[:balance]
  end

  test "a request produces delayed durable progress without polling or sleeping" do
    @client.expects(:request_statement_page).once.returns(status: "requested", reference: "ref_1", evidence: { "response_xml" => "request" })
    page = build_adapter.list_accounts
    assert_not page.complete?
    assert_empty page.records
    assert_nil page.next_cursor
    assert page.progress_cursor
    assert_equal (@observed_at + 3).iso8601(9), page.coverage["available_at"]
    assert_equal "statement_pending", page.warnings.sole["code"]
    early = build_adapter.list_accounts(cursor: page.progress_cursor)
    assert_equal page.progress_cursor, early.progress_cursor
    assert_nil early.next_cursor
  end

  test "one poll resumes the saved reference and shares the resulting statement across resources" do
    @client.expects(:request_statement_page).returns(status: "requested", reference: "ref_1", evidence: {})
    pending = build_adapter.list_accounts
    @client.expects(:poll_statement_page).with(reference: "ref_1").once.returns(status: "ready", reference: "ref_1", xml: @xml, evidence: {})
    resumed = build_adapter(observed_at: @observed_at + 3)
    inventory = resumed.list_accounts(cursor: pending.progress_cursor)
    assert inventory.complete?
    assert_equal BigDecimal("3351"), resumed.fetch_balance(account: inventory.records.first).records.sole[:balance]
    assert_equal BigDecimal("10"), resumed.fetch_holdings(account: inventory.records.first).records.sole[:quantity]
  end

  test "pending polls increase the saved attempt count and budget stops further HTTP" do
    state = { version: 1, resource: "inventory", phase: "poll", reference: "ref_1", attempts: 19, available_at: @observed_at.iso8601 }
    @client.expects(:poll_statement_page).with(reference: "ref_1").once.returns(status: "pending", reference: "ref_1", evidence: { "status" => "pending" })
    page = build_adapter.list_accounts(cursor: encoded(state))
    assert_equal 20, JSON.parse(Base64.urlsafe_decode64(page.progress_cursor)).fetch("attempts")
    assert_raises(Provider::AccountData::IncompletePage) { build_adapter(observed_at: @observed_at + 3).list_accounts(cursor: page.progress_cursor) }
  end

  test "poll responses cannot substitute a different statement reference" do
    state = { version: 1, resource: "inventory", phase: "poll", reference: "ref_1", attempts: 0, available_at: @observed_at.iso8601 }
    @client.expects(:poll_statement_page).returns(status: "ready", reference: "other", xml: @xml, evidence: {})
    assert_raises(Provider::AccountData::InvalidResponse) { build_adapter.list_accounts(cursor: encoded(state)) }
  end

  test "holdings aggregate complete tax lots without changing conid date currency identity" do
    row = statement_data.fetch("open_positions").first
    second = row.merge("position" => "5", "cost_basis_price" => "100")
    record = @adapter.normalize_holding([ row, second ], account: @account)
    assert_equal "ibkr_U1234567_265598_2026-05-08_USD", record[:external_id]
    assert_equal BigDecimal("15"), record[:quantity]
    assert_equal BigDecimal("2250"), record[:amount]
    assert_equal BigDecimal("117"), record[:metadata][:cost_basis]
    assert_equal({ ticker: "AAPL", name: "AAPL", lookup: "ticker_only" }, record[:security])
    assert_equal "US0378331005", record[:metadata][:security_id]
    assert_equal false, @adapter.fetch_holdings(account: @account).coverage["absence_authoritative"]
  end

  test "a corrupt or inconsistent tax lot cannot silently shrink a holding" do
    row = statement_data.fetch("open_positions").first
    [ { "cost_basis_price" => "NaN" }, { "mark_price" => "200" }, { "fx_rate_to_base" => "0" }, { "symbol" => "OTHER" } ].each do |change|
      assert_raises(ArgumentError) { @adapter.normalize_holding([ row, row.merge(change) ], account: @account) }
    end
  end

  test "unsupported short and derivative holdings do not become long stock positions" do
    xml = @xml.gsub('side="Long"', 'side="Short"')
    adapter = build_adapter(staged_xml: xml)
    assert_empty adapter.fetch_holdings(account: adapter.list_accounts.records.first).records
    assert_empty @adapter.normalize_trade(statement_data.fetch("trades").first.merge("asset_category" => "OPT"), account: @account)
  end

  test "trades and their separate commissions preserve legacy signs IDs labels and FX" do
    rows = statement_data.fetch("trades")
    imported = legacy_activities(trades: rows, cash_transactions: [])
    records = rows.flat_map { |row| @adapter.normalize_trade(row, account: @account) }
    assert_equal %w[ibkr_trade_1001 ibkr_trade_fee_1001 ibkr_trade_1002 ibkr_trade_fee_1002], records.map { |row| row[:external_id] }
    records.each do |record|
      old = imported.fetch(record[:external_id])
      %i[external_id name date amount currency].each { |key| assert_equal old[key], record[key] }
      if record.ledger_type == "trade"
        %i[quantity price].each { |key| assert_equal old[key], record[key] }
        assert_equal old[:activity_label], record[:metadata][:investment_activity_label]
        assert_equal BigDecimal(old[:exchange_rate].to_s), record[:metadata][:exchange_rate]
      else
        assert_equal "Fee", record[:metadata][:investment_activity_label]
        assert_equal "USD", record[:currency]
      end
    end
    assert_equal BigDecimal("280"), records.first[:amount]
    assert_equal BigDecimal("-155"), records.third[:amount]
  end

  test "cash deposits withdrawals and dividends retain cash representation and source identity" do
    data = statement_data
    rows = data.fetch("cash_transactions") + [ data.fetch("cash_transactions").first.merge("transaction_id" => "out", "amount" => "-200") ]
    imported = legacy_activities(trades: [], cash_transactions: rows)
    rows.each do |row|
      record = @adapter.normalize_cash(row, account: @account, data: data)
      expected = imported.fetch(record[:external_id])
      assert_equal "transaction", record.ledger_type
      %i[external_id name date amount currency].each { |key| assert_equal expected[key], record[key] }
      assert_equal expected[:investment_activity_label], record[:metadata][:investment_activity_label]
    end
    assert_nil @adapter.normalize_cash(rows.first.merge("type" => "Other Fees"), account: @account, data: data)
    assert_nil @adapter.normalize_cash(rows.first.merge("amount" => "0"), account: @account, data: data)
  end

  test "foreign activity needs an exact positive rate and prices reject floating point" do
    row = statement_data.fetch("trades").first
    assert_raises(Provider::AccountData::IncompletePage) { @adapter.normalize_trade(row.except("fx_rate_to_base"), account: @account) }
    assert_raises(ArgumentError) { @adapter.normalize_trade(row.merge("fx_rate_to_base" => "-1"), account: @account) }
    assert_raises(ArgumentError) { @adapter.normalize_trade(row.merge("trade_price" => 1.5), account: @account) }
    zero = @adapter.normalize_trade(row.merge("quantity" => "0", "ib_commission" => "0"), account: @account).sole
    assert zero[:metadata][:allow_zero_quantity]
  end

  test "activities complete only after both sections and completed cursor never skips the next export" do
    trades = @adapter.fetch_activities(account: @account)
    assert_not trades.complete?
    assert_equal 4, trades.records.size
    restored = build_adapter(staged_xml: @xml)
    cash = restored.fetch_activities(account: @account, cursor: trades.progress_cursor)
    assert cash.complete?
    assert_equal %w[ibkr_cash_4001 ibkr_cash_4002], cash.records.map { |row| row[:external_id] }
    assert cash.checkpoint_cursor
    again = restored.fetch_activities(account: @account, cursor: cash.checkpoint_cursor)
    assert_equal trades.records.map(&:attributes), again.records.map(&:attributes)
    assert_equal "configured_flex_query", cash.coverage["scope"]
  end

  test "page resumption requires the original XML and exact account scope" do
    page = @adapter.fetch_activities(account: @account)
    assert_raises(Provider::AccountData::IncompletePage) { build_adapter.fetch_activities(account: @account, cursor: page.progress_cursor) }
    changed = build_adapter(staged_xml: @xml.sub('tradePrice="140.00"', 'tradePrice="141.00"'))
    assert_raises(Provider::AccountData::IncompletePage) { changed.fetch_activities(account: @account, cursor: page.progress_cursor) }
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_activities(account: @adapter.list_accounts.records.last, cursor: page.progress_cursor) }
  end

  test "missing sections and ambiguous balance totals cannot be accepted as empty or zero" do
    xml = @xml.sub("<CashTransactions />", "")
    adapter = build_adapter(staged_xml: xml)
    account = adapter.list_accounts.records.last
    assert_raises(Provider::AccountData::IncompletePage) { adapter.fetch_activities(account: account) }
    xml = @xml.sub('<CashReportCurrency currency="BASE_SUMMARY" endingCash="250.00" />', "")
    assert_raises(Provider::AccountData::IncompletePage) { build_adapter(staged_xml: xml).list_accounts }
  end

  test "inventory slices are bounded and require digest matched restoration" do
    document = Nokogiri::XML(@xml)
    template = document.at_xpath("//FlexStatement").dup
    wrapper = document.at_xpath("//FlexStatements")
    wrapper.children.remove
    101.times do |index|
      copy = template.dup
      copy.xpath(".//*[@accountId] | .").each { |node| node["accountId"] = "account-#{index}" if node["accountId"] }
      wrapper.add_child(copy)
    end
    wrapper["count"] = "101"
    xml = document.to_xml
    first = build_adapter(staged_xml: xml).list_accounts
    assert_equal 100, first.records.size
    assert_not first.complete?
    last = build_adapter(staged_xml: xml).list_accounts(cursor: first.progress_cursor)
    assert last.complete?
    assert_equal "account-100", last.records.sole[:external_id]
    assert_raises(Provider::AccountData::IncompletePage) { build_adapter(staged_xml: @xml).list_accounts(cursor: first.progress_cursor) }
  end

  test "malformed XML ambiguous account IDs cross account rows and future reports are rejected" do
    values = [ "<FlexQueryResponse>", @xml.sub('count="2"', 'count="3"'),
      @xml.sub('accountId="U1234567" currency="CHF"', 'accountId="other" currency="CHF"'),
      @xml.sub('accountId="U1234567" currency="BASE_SUMMARY"', 'accountId="other" currency="BASE_SUMMARY"'),
      @xml.sub('toDate="2026-05-08"', 'toDate="2027-05-08"'), '<!DOCTYPE a [<!ENTITY x SYSTEM "file:///secret">]><FlexQueryResponse />' ]
    values.each { |xml| assert_raises(Provider::AccountData::InvalidResponse) { build_adapter(staged_xml: xml) } }
  end

  test "Flex values preserve decimal precision parentheses and report date without timezone drift" do
    values = Provider::AccountData::Ibkr::Values
    assert_equal BigDecimal("-1234.123456789012345678"), values.decimal("(1,234.123456789012345678)")
    assert_equal Date.new(2026, 5, 8), values.date("20260508;003001")
    [ "NaN", "Infinity", "1,00", "1.2tail", 1.2 ].each { |value| assert_raises(ArgumentError) { values.decimal(value) } }
    [ "20260508;246001", "2026-02-30", "2026-05-08 junk" ].each { |value| assert_raises(ArgumentError) { values.date(value) } }
  end

  private
    def build_adapter(observed_at: @observed_at, **options)
      Provider::AccountData::Ibkr.new(client: @client, timezone: "UTC", observed_at: observed_at, **options)
    end

    def encoded(state)
      Base64.urlsafe_encode64(JSON.generate(state), padding: false)
    end

    def statement_data
      Provider::AccountData::Ibkr::Statement.new(@xml, observed_on: @observed_at.to_date).accounts.first
    end

    def legacy_activities(trades:, cash_transactions:)
      linked = OpenStruct.new(currency: "CHF")
      legacy = OpenStruct.new(current_account: linked, currency: "CHF", raw_holdings_payload: statement_data.fetch("open_positions"),
        raw_activities_payload: { trades: trades, cash_transactions: cash_transactions })
      imported = {}
      importer = mock("legacy financial boundary")
      Account::ProviderImportAdapter.expects(:new).at_least_once.with(linked).returns(importer)
      importer.stubs(:import_trade).with { |**values| imported[values.fetch(:external_id)] = values }.returns(:entry)
      importer.stubs(:import_transaction).with { |**values| imported[values.fetch(:external_id)] = values }.returns(:entry)
      processor = IbkrAccount::ActivitiesProcessor.new(legacy)
      processor.stubs(:resolve_security).returns(OpenStruct.new(ticker: "AAPL", id: "security"))
      processor.process
      imported
    end
end
