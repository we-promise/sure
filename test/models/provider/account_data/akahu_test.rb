require "test_helper"

class Provider::AccountData::AkahuTest < ActiveSupport::TestCase
  setup do
    @client = mock("Akahu transport")
    @adapter = Provider::AccountData::Akahu.new(client: @client, timezone: "Pacific/Auckland")
    @account = Ingestion::Record.account(external_id: "acc_1", name: "Checking", currency: "NZD")
  end

  test "builds from both encrypted tokens without fetching data" do
    Provider::Akahu.expects(:new).with(app_token: "app", user_token: "user").returns(@client)
    adapter = Provider::AccountData::Akahu.build(credentials: { "app_token" => "app", "user_token" => "user" }, settings: {}, context: { timezone: "Pacific/Auckland" })

    assert_instance_of Provider::AccountData::Akahu, adapter
  end

  test "initial acquisition preserves explicit cutover dates and an unbounded nil" do
    assert_equal [ "akahu_initial_history_start" ], Provider::AccountData::Akahu.initial_history_metadata_keys
    [ {}, { "akahu_initial_history_start" => nil } ].each do |metadata|
      assert_nil @adapter.initial_history_start(account: { metadata: metadata }, observed_at: Time.current)
    end
    assert_equal Date.new(2020, 1, 2), @adapter.initial_history_start(
      account: { metadata: { "akahu_initial_history_start" => "2020-01-02" } }, observed_at: Time.current)
  end

  test "malformed cutover history hints cannot silently widen the first request" do
    [ "", false, 0, "2020-02-30", "2020-01-02T00:00:00Z", {} ].each do |value|
      assert_raises(Provider::AccountData::InvalidResponse) do
        @adapter.initial_history_start(account: { metadata: { "akahu_initial_history_start" => value } }, observed_at: Time.current)
      end
    end
  end

  test "account values retain balance policy institution and encrypted sensitive details" do
    record = @adapter.normalize_account({
      _id: "acc_1", name: "Checking", type: "CHECKING", balance: { current: BigDecimal("-123.45"), available: 100, limit: 500, currency: " nzd " },
      connection: { _id: "bank_1", name: "Bank", logo: "https://bank.test/logo.png" },
      meta: { payment_details: { account_number: "private-account", account_holder: "Owner" } }
    })

    assert_equal "Bank - Checking", record[:name]
    assert_equal BigDecimal("-123.45"), record[:balance]
    assert_equal BigDecimal("100"), record[:available_balance]
    assert_equal "NZD", record[:currency]
    assert_equal "private-account", record[:sensitive_details][:account_number]
    refute record[:metadata][:institution].key?(:account_number)
    assert_equal %w[CreditCard Loan], record[:metadata][:balance_policy][:debt_types]
    assert_equal true, record[:metadata][:balance_policy][:investment_cash_zero]
  end

  test "normalizes exact signs merchant website notes and every legacy category metadata field" do
    record = @adapter.normalize_transaction(transaction(
      merchant: { _id: "merchant_1", name: " Shop ", website: "https://shop.test" },
      category: { _id: "category_1", name: "Shopping", groups: { personal_finance: { name: "Expenses" } } },
      meta: { reference: "Reference", particulars: "Particulars", code: "Code", other_account: "Other" }
    ), account: @account)

    assert_equal "akahu_tx_1", record[:external_id]
    assert_equal BigDecimal("0.123456789012345678"), record[:amount]
    assert_equal "Shop", record[:name]
    assert_equal "https://shop.test", record[:metadata][:merchant][:website_url]
    assert_includes record[:metadata][:notes], "Card payment"
    assert_includes record[:metadata][:notes], "Reference"
    assert_equal "category_1", record[:metadata][:extra]["akahu"]["category_id"]
    assert_equal "Expenses", record[:metadata][:extra]["akahu"]["category_group"]
    assert_equal "Other", record[:metadata][:extra]["akahu"]["other_account"]
    assert_equal false, record[:metadata][:extra]["akahu"]["pending"]
  end

  test "idless pending identity preserves legacy float formatting without rounding financial values" do
    raw = transaction(_id: nil, amount: BigDecimal("-9.95"), pending: true, merchant: { name: " Shop " })
    identity = [ "acc_1", raw[:date], -9.95, "Card payment", "Shop", "DEBIT" ].join("|")
    record = @adapter.normalize_transaction(raw, account: @account)

    assert_equal "akahu_pending_#{Digest::MD5.hexdigest(identity)}", record[:external_id]
    assert_equal "reuse_pending_or_allocate_suffix", record[:metadata][:identity_policy]
    assert_equal BigDecimal("9.95"), record[:amount]
    assert record[:pending]
  end

  test "cached float money preserves legacy decimal conversion without changing API parsing" do
    raw = transaction(amount: -12.34)
    before = raw.deep_dup
    record = @adapter.normalize_legacy_transaction(raw, account: @account)

    assert_equal BigDecimal("12.34"), record[:amount]
    assert_equal before, raw
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
    [ Float::INFINITY, -Float::INFINITY, Float::NAN ].each do |value|
      assert_raises(Provider::AccountData::InvalidResponse) do
        @adapter.normalize_legacy_transaction(transaction(amount: value), account: @account)
      end
    end
  end

  test "applies the family timezone and currency fallback" do
    record = @adapter.normalize_transaction(transaction(date: "2026-01-14T14:00:00Z", currency: "invalid"), account: @account)

    assert_equal Date.new(2026, 1, 15), record[:date]
    assert_equal "NZD", record[:currency]
  end

  test "posted history cannot complete until all current pending pages are fetched" do
    raw_response = { "items" => [ transaction ], "cursor" => {}, "private_context" => "account-evidence" }
    @client.expects(:get_account_transactions_page).with(account_id: "acc_1", start_date: "2026-01-01T00:00:00Z", end_date: nil, cursor: nil)
      .returns(items: [ transaction ], next_cursor: nil, evidence: raw_response)
    posted = @adapter.fetch_transactions(account: @account, window: { start: "2026-01-01T00:00:00Z" })
    refute posted.complete?
    assert posted.next_cursor
    assert_equal raw_response, posted.evidence["response"]
    refute_includes posted.inspect, "account-evidence"
    @client.expects(:get_pending_transactions_page).with(cursor: nil).returns(items: [ transaction(_id: "hold_1"), transaction(_id: "other_hold", _account: "other_account") ], next_cursor: nil)

    pending = @adapter.fetch_transactions(account: @account, cursor: posted.next_cursor, window: { start: "2026-01-01T00:00:00Z" })

    assert pending.complete?
    assert_equal [ "akahu_hold_1" ], pending.records.map { |record| record[:external_id] }
    assert pending.records.first[:pending]
    assert_equal "all", pending.coverage["pending_scope"]
  end

  test "resumes each posted and pending page before declaring snapshot completion" do
    @client.expects(:get_account_transactions_page).with(account_id: "acc_1", start_date: nil, end_date: nil, cursor: nil)
      .returns(items: [], next_cursor: "posted-2")
    first = @adapter.fetch_transactions(account: @account)
    @client.expects(:get_account_transactions_page).with(account_id: "acc_1", start_date: nil, end_date: nil, cursor: "posted-2")
      .returns(items: [], next_cursor: nil)
    second = @adapter.fetch_transactions(account: @account, cursor: first.next_cursor)
    @client.expects(:get_pending_transactions_page).with(cursor: nil).returns(items: [], next_cursor: "pending-2")
    third = @adapter.fetch_transactions(account: @account, cursor: second.next_cursor)
    @client.expects(:get_pending_transactions_page).with(cursor: "pending-2").returns(items: [], next_cursor: nil)
    last = @adapter.fetch_transactions(account: @account, cursor: third.next_cursor)

    refute first.complete?
    refute second.complete?
    refute third.complete?
    assert last.complete?
  end

  test "pending failures preserve incompleteness rather than return empty snapshots" do
    @client.expects(:get_account_transactions_page).returns(items: [], next_cursor: nil)
    posted = @adapter.fetch_transactions(account: @account)
    @client.expects(:get_pending_transactions_page).raises(Provider::Akahu::AkahuError.new("Rate limited", :rate_limited))

    assert_raises(Provider::Akahu::AkahuError) { @adapter.fetch_transactions(account: @account, cursor: posted.next_cursor) }
  end

  test "idless pending occurrences remain distinct across response pages and replay" do
    raw = transaction(_id: nil, amount: "-10", pending: true)
    @client.expects(:get_account_transactions_page).returns(items: [], next_cursor: nil)
    posted = @adapter.fetch_transactions(account: @account)
    @client.expects(:get_pending_transactions_page).with(cursor: nil).returns(items: [ raw, raw ], next_cursor: "pending-2")
    first = @adapter.fetch_transactions(account: @account, cursor: posted.next_cursor)
    @client.expects(:get_pending_transactions_page).with(cursor: "pending-2").twice.returns(items: [ raw ], next_cursor: nil)
    second = @adapter.fetch_transactions(account: @account, cursor: first.next_cursor)
    replay = @adapter.fetch_transactions(account: @account, cursor: first.next_cursor)

    assert_equal [ 0, 1 ], first.records.map { |record| record[:metadata][:identity_occurrence] }
    assert_equal 2, second.records.first[:metadata][:identity_occurrence]
    assert_equal second.records.first.attributes, replay.records.first.attributes
  end

  test "rejects invalid money ownership dates and opaque cursors with sanitized errors" do
    [ transaction(amount: nil), transaction(amount: 1.25), transaction(_account: "other"), transaction(date: "private-date") ].each do |raw|
      error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
      assert_nil error.cause
      refute_includes error.message, "private-date"
    end
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_transactions(account: @account, cursor: "not-json") }
  end

  private
    def transaction(**overrides)
      { _id: "tx_1", _account: "acc_1", amount: "-0.123456789012345678", currency: "NZD",
        date: "2026-01-15T08:00:00+13:00", description: "Card payment", type: "DEBIT" }.merge(overrides)
    end
end
