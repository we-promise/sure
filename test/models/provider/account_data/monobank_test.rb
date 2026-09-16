require "test_helper"

class Provider::AccountData::MonobankTest < ActiveSupport::TestCase
  class Client
    attr_reader :requests
    attr_accessor :pages, :inventory

    def initialize
      @requests = []
      @pages = []
    end

    def get_accounts_page
      inventory
    end

    def get_statement_page(account_id:, from:, to:, before_request:)
      before_request.call
      requests << { account_id: account_id, from: from, to: to }
      result = pages.shift
      raise result if result.is_a?(Exception)
      result
    end
  end

  setup do
    @client = Client.new
    @observed_at = Time.utc(2026, 2, 15, 12)
    @adapter = adapter
    @account = Ingestion::Record.account(external_id: "card_1", name: "Card", currency: "UAH")
  end

  test "factory receives explicit runtime configuration and keeps activation gated" do
    Provider::Monobank.expects(:new).with("token").returns(@client)
    linked = { id: "account-1", currency: "UAH", accountable_type: "Depository", accountable_id: "depository-1",
      account_provider_id: "link-1", account_provider_revision: 0 }
    external = { id: "external-1", external_id: "card_1", identity_namespace: "connection", linked_account: linked, sync_start_date: nil }
    retained = { version: 1, accounts: { "external-1" => { state: {}, context: {
      external_id: "card_1", identity_namespace: "connection", sync_start_date: nil,
      account_binding: { link: { id: "link-1", account_id: "account-1", external_account_id: "external-1", lock_version: 0 },
        financial_context: linked.slice(:id, :currency, :accountable_type, :accountable_id) }
    } } } }
    built = Provider::AccountData::Monobank.build(credentials: { access_token: "token" }, settings: {}, context: {
      timezone: "Europe/Kyiv", observed_at: @observed_at,
      configured_options: { include_pending: false, max_statement_requests_per_sync: 1 },
      external_accounts: [ external ], monobank_retained_history: retained
    })
    @client.pages = [ page([ transaction(hold: true) ]) ]
    account = Ingestion::Record.account(**@account.attributes.merge(metadata: {
      runtime_external_account_id: "external-1", runtime_identity_namespace: "connection"
    }))

    assert_empty built.fetch_transactions(account: account).records
    refute Provider::AccountData::Monobank.native_ready?
    assert_equal %i[include_pending max_statement_requests_per_sync pending_lookback_days initial_history_days], Provider::AccountData::Monobank.runtime_options
  end

  test "cards subtract credit limits while jars and currency minor units retain their balances" do
    card = @adapter.normalize_account({ id: "card_1", kind: "card", type: "black", balance: 250_000, creditLimit: 100_000,
      currencyCode: 980, maskedPan: [ "4444******1234" ], iban: "private-iban" })
    jar = @adapter.normalize_account({ id: "jar_1", kind: "jar", title: "Trip", balance: 1234, currencyCode: 392 })

    assert_equal BigDecimal("1500"), card[:balance]
    assert_equal card[:balance], card[:cash_balance]
    assert_equal BigDecimal("1000"), card[:metadata][:credit_limit]
    assert_equal "private-iban", card[:sensitive_details][:iban]
    assert_match(/1234\z/, card[:name])
    assert_equal "Trip", jar[:name]
    assert_equal "jar", jar[:account_type]
    assert_equal "JPY", jar[:currency]
    assert_equal BigDecimal("1234"), jar[:balance]
  end

  test "inventory retains private response evidence and warns on the legacy currency fallback" do
    raw = { id: "card_1", kind: "card", type: "black", balance: 100, currencyCode: 999 }
    @client.inventory = page([ raw ]).merge(evidence: { "accounts" => [ raw ], "name" => "private-holder" })

    result = @adapter.list_accounts

    assert_equal "UAH", result.records.first[:currency]
    assert_equal "unrecognized_account_currency", result.warnings.first["code"]
    assert_equal "private-holder", result.evidence["response"]["name"]
    refute_includes result.records.first[:metadata].inspect, "private-holder"
  end

  test "main amount stays in account currency while foreign operation metadata uses its own divisor" do
    record = @adapter.normalize_transaction(transaction(amount: -50_000, currencyCode: 978, operationAmount: -1000,
      cashbackAmount: 100, commissionRate: 250, balance: 300_000, counterName: "Counterparty", counterIban: "private-counter-iban"), account: @account)
    details = record[:metadata][:extra]["monobank"]

    assert_equal "monobank_tx_1", record[:external_id]
    assert_equal BigDecimal("500"), record[:amount]
    assert_equal "UAH", record[:currency]
    assert_equal "EUR", details["fx_from"]
    assert_equal "-10.0", details["fx_amount"]
    assert_equal -1000, details["operation_amount"]
    assert_equal "1.0", details["cashback_amount"]
    assert_equal "2.5", details["commission_amount"]
    assert_equal "3000.0", details["balance_after"]
    assert_equal "private-counter-iban", details["counter_iban"]
  end

  test "income pending date merchant notes and category candidates preserve legacy semantics" do
    raw = transaction(amount: 123_456, hold: "true", description: " Shop ", comment: "My note", mcc: 5411,
      time: Time.utc(2026, 2, 14, 23, 30).to_i.to_s)
    record = @adapter.normalize_transaction(raw, account: @account)

    assert_equal BigDecimal("-1234.56"), record[:amount]
    assert record[:pending]
    assert_equal Date.new(2026, 2, 15), record[:date]
    assert_equal "My note", record[:metadata][:notes]
    assert_equal "Shop", record[:metadata][:merchant][:name]
    assert_equal "monobank_merchant_#{Digest::MD5.hexdigest('shop')}", record[:metadata][:merchant][:external_id]
    assert_equal "groceries", record[:metadata][:category_candidates][:translation_key]
    assert_equal [ "groceries" ], record[:metadata][:category_candidates][:aliases]
  end

  test "idless transaction identity retains account timestamp amount and description fingerprint" do
    raw = transaction(id: nil)
    expected = Digest::MD5.hexdigest([ "card_1", raw[:time], raw[:amount], raw[:description] ].join("|"))

    assert_equal "monobank_pending_#{expected}", @adapter.normalize_transaction(raw, account: @account)[:external_id]
  end

  test "malformed optional foreign amount remains a partial FX observation with a warning" do
    @client.pages = [ page([ transaction(currencyCode: 978, operationAmount: "invalid-private-value") ]) ]

    result = @adapter.fetch_transactions(account: @account)

    assert result.complete?
    assert_equal "EUR", result.records.first[:metadata][:extra]["monobank"]["fx_from"]
    refute result.records.first[:metadata][:extra]["monobank"].key?("fx_amount")
    assert_equal "unparseable_operation_amount", result.warnings.first["code"]
    refute_includes result.warnings.inspect, "invalid-private-value"
  end

  test "invalid required money ownership dates and cursors fail without leaking raw values" do
    [ transaction(amount: nil), transaction(amount: 12.5), transaction(amount: "12.5"), transaction(account_id: "other"), transaction(time: "private-date") ].each do |raw|
      error = assert_raises(Provider::AccountData::InvalidResponse) { @adapter.normalize_transaction(raw, account: @account) }
      assert_nil error.cause
      refute_includes error.message, "private-date"
    end
    assert_raises(Provider::AccountData::InvalidResponse) { @adapter.fetch_transactions(account: @account, cursor: "invalid") }
  end

  test "forward reads default history and emits a completed checkpoint only after the response arrives" do
    @client.pages = [ page([ transaction ]) ]

    result = @adapter.fetch_transactions(account: @account)

    assert result.complete?
    assert_nil result.progress_cursor
    assert result.checkpoint_cursor
    assert_equal @observed_at - 31.days, @client.requests.first[:from]
    assert_equal @observed_at, @client.requests.first[:to]
    assert_equal true, result.coverage["pending_absence_authoritative"]
  end

  test "long history advances one backward window after current activity" do
    adapter = adapter(initial_history_days: 120)
    @client.pages = [ page([]), page([]) ]

    forward = adapter.fetch_transactions(account: @account)
    history = adapter.fetch_transactions(account: @account, cursor: forward.next_cursor)

    refute forward.complete?
    assert_equal forward.next_cursor, forward.progress_cursor
    assert history.complete?
    assert_equal @observed_at - Provider::Monobank::MAX_STATEMENT_WINDOW, @client.requests.first[:from]
    assert_equal @client.requests.first[:from], @client.requests.second[:to]
    assert_equal @client.requests.second[:to] - Provider::Monobank::MAX_STATEMENT_WINDOW, @client.requests.second[:from]
  end

  test "generic initial window keeps provider history defaults while an explicit start requests backfill" do
    @client.pages = [ page([]), page([]) ]
    generic = @adapter.fetch_transactions(account: @account,
      window: { start: (@observed_at - 90.days).iso8601, end: @observed_at.iso8601, initial: true, explicit_start: false })
    explicit = adapter.fetch_transactions(account: @account,
      window: { start: (@observed_at - 120.days).iso8601, end: @observed_at.iso8601, initial: true, explicit_start: true })

    assert generic.complete?
    assert_equal @observed_at - 31.days, @client.requests.first[:from]
    refute explicit.complete?
    assert_equal @observed_at - Provider::Monobank::MAX_STATEMENT_WINDOW, @client.requests.second[:from]
    assert explicit.progress_cursor
  end

  test "capped responses expose resumable progress and repeat the inclusive timestamp boundary" do
    rows = Array.new(500) { |index| transaction(id: "tx_#{index}", time: @observed_at.to_i - index) }
    @client.pages = [ page(rows), page([]) ]

    partial = @adapter.fetch_transactions(account: @account)
    resumed = adapter(observed_at: @observed_at + 1.day).fetch_transactions(account: @account, cursor: partial.progress_cursor)

    refute partial.complete?
    assert_nil partial.checkpoint_cursor
    assert_equal partial.next_cursor, partial.progress_cursor
    assert_equal "statement_item_cap", partial.warnings.first["code"]
    assert_equal @observed_at - 499, @client.requests.second[:to]
    assert resumed.complete?
    assert_equal @observed_at.iso8601, resumed.coverage["end"]
    assert_equal false, resumed.coverage["pending_absence_authoritative"]
  end

  test "a full same-second response cannot claim completion or loop without making progress" do
    @client.pages = [ page(Array.new(500) { |index| transaction(id: "tx_#{index}", time: @observed_at.to_i) }) ]

    assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_transactions(account: @account) }
  end

  test "statement request budget applies across accounts before another HTTP call" do
    adapter = adapter(request_budget: 1)
    @client.pages = [ page([]) ]
    adapter.fetch_transactions(account: @account)

    assert_raises(Provider::AccountData::BudgetExhausted) { adapter.fetch_transactions(account: @account) }
    assert_equal 1, @client.requests.size
  end

  test "rate limiting defers incomplete statement work without claiming an empty response" do
    @client.pages = [ Provider::Monobank::RateLimitError.new("Limited", failure_code: :rate_limited) ]

    error = assert_raises(Provider::AccountData::IncompletePage) { @adapter.fetch_transactions(account: @account) }

    assert_nil error.cause
    assert_equal 1, @client.requests.size
  end

  test "completed checkpoints retain the oldest hold for later forward overlap" do
    @client.pages = [ page([ transaction(hold: true, time: (@observed_at - 10.days).to_i) ]), page([]) ]
    first = @adapter.fetch_transactions(account: @account)

    adapter(observed_at: @observed_at + 1.day).fetch_transactions(account: @account, cursor: first.checkpoint_cursor)

    assert_equal @observed_at - 10.days, @client.requests.second[:from]
  end

  test "pending preference filters held records and marks the explicit pending scope" do
    @client.pages = [ page([ transaction(hold: true), transaction(id: "settled", hold: false) ]) ]

    result = adapter(include_pending: false).fetch_transactions(account: @account)

    assert_equal [ "monobank_settled" ], result.records.map { |record| record[:external_id] }
    assert_equal "all", result.coverage["pending_scope"]
  end

  test "migrated forward history and oldest hold state set the overlap without touching legacy models" do
    adapter = adapter(account_states: { "card_1" => { statement_synced_through: @observed_at - 1.day,
      history_synced_from: @observed_at - 31.days, oldest_pending_at: @observed_at - 10.days } })
    @client.pages = [ page([]) ]

    result = adapter.fetch_transactions(account: @account)

    assert result.complete?
    assert_equal @observed_at - 10.days, @client.requests.first[:from]
  end

  private
    def adapter(**options)
      Provider::AccountData::Monobank.new(client: @client, timezone: "Europe/Kyiv", observed_at: @observed_at, **options)
    end

    def page(items)
      { items: items, next_cursor: nil, evidence: items }
    end

    def transaction(**options)
      { id: "tx_1", time: @observed_at.to_i - 60, amount: -1234, operationAmount: -1234, currencyCode: 980,
        description: "Shop", hold: false, account_id: "card_1" }.merge(options)
    end
end
