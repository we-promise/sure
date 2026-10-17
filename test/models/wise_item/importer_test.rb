require "test_helper"

class WiseItem::ImporterTest < ActiveSupport::TestCase
  # Behaves like Wise where the importer depends on it: transfers come in
  # offset pages ending with an empty page, activities in nextCursor pages,
  # and a transfer is readable by id only when listed in transfer_details.
  # An offset that is not a multiple of the limit is refused as Wise refuses
  # it (HTTP 422 inconsistent.pagination).
  # transfer_pages: { offset => rows } instead of slices of `transfers`.
  # windowed_activities: only the activities created at or after `since`
  # come back (the field Wise filters on is undocumented; this is the
  # narrowest reading).
  class FakeWiseProvider
    WiseResponse = Struct.new(:code, :body, :headers)

    attr_reader :calls, :statement_requests, :transfer_requests, :activity_requests, :transfer_reads

    def initialize(balances: nil, savings_balances: nil, borderless_accounts: nil, multi_currency_account: nil,
                   transfers: nil, transfer_pages: nil, transfer_details: {}, activities: nil, activity_pages: nil, windowed_activities: false,
                   statements: nil, raise_on: {}, statement_fail_balance_ids: [])
      @balances = balances || [ standard_balance ]
      @savings_balances = savings_balances || []
      @borderless_accounts = borderless_accounts || [ borderless_account ]
      @multi_currency_account = multi_currency_account || default_multi_currency_account
      @transfers = transfers || []
      @transfer_pages = transfer_pages
      @transfer_details = transfer_details
      @activities = activities || []
      @activity_pages = activity_pages
      @windowed_activities = windowed_activities
      @statements = statements || []
      @raise_on = raise_on
      @statement_fail_balance_ids = statement_fail_balance_ids
      @calls = []
      @statement_requests = []
      @transfer_requests = []
      @activity_requests = []
      @transfer_reads = []
    end

    def get_balances(profile_id)
      @calls << :get_balances
      raise_if(:get_balances)
      @balances
    end

    def get_savings_balances(profile_id)
      @calls << :get_savings_balances
      raise_if(:get_savings_balances)
      @savings_balances
    end

    def get_borderless_accounts(profile_id)
      @calls << :get_borderless_accounts
      raise_if(:get_borderless_accounts)
      @borderless_accounts
    end

    def get_multi_currency_account(profile_id)
      @calls << :get_multi_currency_account
      raise_if(:get_multi_currency_account)
      @multi_currency_account
    end

    def get_transfers(profile_id, limit: 100, offset: 0, created_date_start: nil, created_date_end: nil)
      @calls << :get_transfers
      @transfer_requests << { offset: offset, limit: limit, created_date_start: created_date_start }
      raise_if(:get_transfers)
      refuse_inconsistent_pagination(offset) unless (offset % limit).zero?
      return Array(@transfer_pages[offset]) if @transfer_pages

      @transfers[offset, limit] || []
    end

    def get_transfer(transfer_id)
      @calls << :get_transfer
      @transfer_reads << transfer_id
      raise_if(:get_transfer)
      @transfer_details.fetch(transfer_id.to_s) { raise Provider::Wise::WiseError.new("Resource not found", :not_found) }
    end

    def get_balance_statements(profile_id, balance_id, currency:, start_date:, end_date:)
      @calls << :get_balance_statements
      @statement_requests << { profile_id: profile_id, balance_id: balance_id, currency: currency,
                               start_date: start_date, end_date: end_date }
      raise_if(:get_balance_statements)
      raise Provider::Wise::WiseError.new("forbidden", :fetch_failed) if @statement_fail_balance_ids.include?(balance_id)
      @statements
    end

    def get_activities(profile_id, cursor: nil, size: 100, since: nil, until_time: nil)
      @calls << :get_activities
      @activity_requests << { cursor: cursor, size: size, since: since }
      raise_if(:get_activities)
      return @activity_pages.fetch(cursor) if @activity_pages

      activities = @activities
      if @windowed_activities && since
        activities = activities.select { |activity| ActiveSupport::TimeZone["UTC"].parse(activity["createdOn"]) >= since }
      end
      { "activities" => activities, "cursor" => nil }
    end

    private

      # A message raises a generic fetch failure; an error instance is raised as is.
      def raise_if(method)
        error = @raise_on[method]
        raise error if error.is_a?(Exception)
        raise Provider::Wise::WiseError.new(error, :fetch_failed) if error
      end

      # Wise's 422 body, raised as Provider::Wise raises it.
      def refuse_inconsistent_pagination(offset)
        body = { "errors" => [ { "code" => "inconsistent.pagination", "message" => "Inconsistent pagination in filter",
                                 "field" => "offset", "arguments" => [ "offset", offset ] } ] }.to_json
        Provider::Wise.new("test_token").send(:handle_response, WiseResponse.new(422, body, {}))
      end

      def default_multi_currency_account
        { "id" => 77001, "recipientId" => 99999001, "creationTime" => "2020-05-20T14:43:16.658Z" }
      end

      def standard_balance
        {
          "id" => "10000001",
          "amount" => { "value" => 1964.88, "currency" => "EUR" },
          "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
          "type" => "STANDARD"
        }
      end

      def borderless_account
        {
          "id" => 88888001,
          "recipientId" => 99999001,
          "balances" => [ { "id" => 10000001 } ]
        }
      end
  end

  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "11111111",
      profile_type: :business
    )
  end

  # STANDARD balance import

  test "imports STANDARD balances and creates WiseAccount records" do
    provider = FakeWiseProvider.new

    result = nil
    assert_no_difference -> { DebugLogEntry.where(provider_key: "wise").count } do
      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
    end

    assert result[:success]
    assert_equal 1, result[:accounts_created]
    assert_equal 0, result[:accounts_updated]

    account = @wise_item.wise_accounts.first
    assert_equal "10000001", account.balance_id
    assert_equal "EUR", account.currency
    assert_not account.jar?
  end

  test "stores borderless_account_id and recipient_id in STANDARD account raw_payload" do
    provider = FakeWiseProvider.new

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(balance_id: "10000001")
    assert_equal 88888001, account.raw_payload["borderless_account_id"]
    assert_equal 99999001, account.raw_payload["recipient_id"]
  end

  # SAVINGS (JAR) balance import

  test "imports SAVINGS balances and marks them as JAR" do
    savings = {
      "id" => "10000002",
      "amount" => { "value" => 11022.16, "currency" => "EUR" },
      "totalWorth" => { "value" => 11022.16, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }
    provider = FakeWiseProvider.new(savings_balances: [ savings ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    jar = @wise_item.wise_accounts.find_by(balance_id: "10000002")
    assert_not_nil jar
    assert jar.jar?
    assert_equal BigDecimal("11022.16"), jar.current_balance
    assert_equal "Jar", jar.name
  end

  # A new balance Sure could not save (a database error, here an amount beyond
  # the column) stayed in the item's balances as an unsaved record, and the
  # import crashed on it ("comparison of WiseAccount with WiseAccount failed")
  # instead of counting it and storing the other balances' rows.
  test "counts a new balance that fails to save and imports the others" do
    eur = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                           raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
                                           raw_transactions_payload: [ build_transfer(id: 1) ])
    provider = FakeWiseProvider.new(balances: [ eur_balance("10000001", 10.0), standard_balance("10000002", "USD", 10**16) ],
                                    transfers: [ build_transfer(id: 1), build_transfer(id: 2) ],
                                    raise_on: { get_balance_statements: statements_forbidden })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_not result[:success]
    assert_equal [ 0, 1, 1, 0 ], result.values_at(:accounts_created, :accounts_updated, :accounts_failed, :transactions_failed)
    assert_equal [ "10000001" ], @wise_item.wise_accounts.reload.map(&:balance_id)
    assert_equal [ 1, 2 ], eur.reload.raw_transactions_payload.map { |row| row["id"] }
    # The unsaved balance received none of the rows coverage would claim.
    assert_nil @wise_item.reload.raw_payload&.dig("coverage")
  end

  # A jar the failed list left out stores none of this sync's rows, so the
  # import is incomplete and its coverage stays: the next sync, which lists
  # the jar, fetches the same window again and the jar gets its moves.
  test "imports the other balances when the savings list fails, but neither completes nor moves coverage" do
    jar = { "id" => "10000002", "type" => "SAVINGS", "name" => "Holiday", "creationTime" => 200.days.ago.utc.iso8601,
            "amount" => { "value" => 1000.0, "currency" => "EUR" }, "totalWorth" => { "value" => 1000.0, "currency" => "EUR" } }
    deposit = build_interbalance("To <strong>Holiday</strong>", resource_id: "5001").merge("createdOn" => 120.days.ago.utc.iso8601)
    import = lambda do |**options|
      provider = FakeWiseProvider.new(savings_balances: [ jar ], activities: [ deposit ], windowed_activities: true,
                                      raise_on: { get_balance_statements: statements_forbidden }.merge(options))
      [ WiseItem::Importer.new(WiseItem.find(@wise_item.id), wise_provider: provider).import, provider ]
    end

    failed, = import.call(get_savings_balances: "Unexpected response 503")
    assert_equal [ false, false, 1 ], failed.values_at(:success, :complete, :fetch_failures)
    assert_equal [ "10000001" ], @wise_item.wise_accounts.reload.map(&:balance_id)
    assert_nil @wise_item.reload.raw_payload&.dig("coverage")

    listed, provider = import.call
    assert listed[:complete]
    assert_equal 365.days.ago.to_date, provider.activity_requests.first[:since].to_date
    assert_equal [ "interbalance_5001" ], payload_ids["10000002"]
  end

  # Transfer routing

  test "routes transfers to matching STANDARD account by source currency" do
    transfers = [
      build_transfer(id: 1, source_currency: "EUR", target_currency: "EUR", target_account: 9999),
      build_transfer(id: 2, source_currency: "USD", target_currency: "USD", target_account: 9999)
    ]
    provider = FakeWiseProvider.new(transfers: transfers, raise_on: { get_balance_statements: "forbidden" })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    eur_account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_equal 1, eur_account.raw_transactions_payload.size
    assert_equal 1, eur_account.raw_transactions_payload.first["id"]
  end

  test "routes incoming transfers to account by target currency" do
    transfers = [
      build_transfer(id: 3, source_currency: "USD", target_currency: "EUR", target_account: 99999001)
    ]
    provider = FakeWiseProvider.new(transfers: transfers, raise_on: { get_balance_statements: "forbidden" })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    eur_account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_equal 1, eur_account.raw_transactions_payload.size
  end

  test "routes an outgoing cross-currency payout only to the funding balance" do
    balances = %w[GBP PLN].each_with_index.map do |currency, i|
      { "id" => "3000000#{i}", "amount" => { "value" => 100.0, "currency" => currency }, "type" => "STANDARD" }
    end
    borderless = [ { "id" => 88888001, "recipientId" => 99999001,
                     "balances" => [ { "id" => 30000000 }, { "id" => 30000001 } ] } ]
    payout = build_transfer(id: 9, source_currency: "GBP", target_currency: "PLN", target_account: 1234)
    provider = FakeWiseProvider.new(balances: balances, borderless_accounts: borderless, transfers: [ payout ],
                                    raise_on: { get_balance_statements: "forbidden" })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal [ 9 ], @wise_item.wise_accounts.find_by(currency: "GBP").raw_transactions_payload.map { |t| t["id"] }
    assert_empty Array(@wise_item.wise_accounts.find_by(currency: "PLN").raw_transactions_payload)
  end

  test "routes a transfer into a balance's own recipient to that balance and to its funding balance" do
    balances = [ %w[GBP 77777000], %w[USD 77777001] ].each_with_index.map do |(currency, recipient_id), i|
      { "id" => "3000000#{i}", "amount" => { "value" => 100.0, "currency" => currency }, "type" => "STANDARD",
        "recipientId" => recipient_id.to_i }
    end
    borderless = [ { "id" => 88888001, "recipientId" => 99999001,
                     "balances" => [ { "id" => 30000000 }, { "id" => 30000001 } ] } ]
    top_up = build_transfer(id: 12, source_currency: "USD", target_currency: "USD", target_account: 77777001)
    funded = build_transfer(id: 13, source_currency: "GBP", target_currency: "USD", target_account: 77777001)
    provider = FakeWiseProvider.new(balances: balances, borderless_accounts: borderless, transfers: [ top_up, funded ],
                                    raise_on: { get_balance_statements: "forbidden" })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal [ 13 ], @wise_item.wise_accounts.find_by(currency: "GBP").raw_transactions_payload.map { |t| t["id"] }
    assert_equal [ 12, 13 ], @wise_item.wise_accounts.find_by(currency: "USD").raw_transactions_payload.map { |t| t["id"] }.sort
  end

  test "drops previously stored transfers that did not move money in the STANDARD balance" do
    payout = build_transfer(id: 10, source_currency: "GBP", target_currency: "PLN", target_account: 1234)
    local = build_transfer(id: 11, source_currency: "PLN", target_currency: "PLN", target_account: 1234)
    pln = @wise_item.wise_accounts.create!(balance_id: "10000001", currency: "PLN", name: "Wise PLN",
                                           raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
                                           raw_transactions_payload: [ payout, local ])
    balances = [ { "id" => "10000001", "amount" => { "value" => 0.0, "currency" => "PLN" }, "type" => "STANDARD" } ]
    provider = FakeWiseProvider.new(balances: balances, transfers: [],
                                    raise_on: { get_balance_statements: "forbidden" })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal [ 11 ], pln.reload.raw_transactions_payload.map { |t| t["id"] }
  end

  test "imports standard account balance statements and honors configured history start" do
    @wise_item.update!(sync_start_date: Date.new(2024, 1, 1))
    statements = [
      {
        "type" => "CREDIT",
        "date" => "2024-01-02T10:00:00Z",
        "amount" => { "value" => "25.00", "currency" => "EUR" },
        "details" => { "description" => "Salary" },
        "referenceNumber" => "statement-1"
      }
    ]
    provider = FakeWiseProvider.new(statements: statements)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_equal statements.first.merge("wise_statement" => true), account.raw_transactions_payload.first
    assert_equal Date.new(2024, 1, 1), provider.statement_requests.first[:start_date]
    assert_equal Date.current, provider.statement_requests.first[:end_date]
  end

  test "fetches full statement history when import_all_history is enabled" do
    @wise_item.update!(import_all_history: true)
    provider = FakeWiseProvider.new(statements: [])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal WiseItem::Importer::FULL_HISTORY_START_DATE, provider.statement_requests.first[:start_date]
    assert_equal Date.current, provider.statement_requests.first[:end_date]
  end

  test "starts full history from balance creation time when available" do
    @wise_item.update!(import_all_history: true)
    balance = {
      "id" => "10000001",
      "amount" => { "value" => 100.0, "currency" => "EUR" },
      "type" => "STANDARD",
      "creationTime" => "2015-04-12T10:00:00Z"
    }
    provider = FakeWiseProvider.new(balances: [ balance ], statements: [])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal Date.new(2015, 4, 12), provider.statement_requests.first[:start_date]
  end

  test "keeps incremental sync window after statements already exist" do
    @wise_item.update!(import_all_history: true)
    statements = [
      {
        "type" => "CREDIT",
        "date" => "2024-01-02T10:00:00Z",
        "amount" => { "value" => "25.00", "currency" => "EUR" },
        "details" => { "description" => "Salary" },
        "referenceNumber" => "statement-1"
      }
    ]
    WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new(statements: statements)).import

    sync = @wise_item.syncs.create!(status: :completed, completed_at: Time.current)

    second_provider = FakeWiseProvider.new(statements: [])
    WiseItem::Importer.new(@wise_item, wise_provider: second_provider).import

    assert_equal (sync.completed_at - 7.days).to_date, second_provider.statement_requests.first[:start_date]
    assert_equal Date.current, second_provider.statement_requests.first[:end_date]
    refute_includes second_provider.calls, :get_transfers
  end

  test "falls back to transfers when every statement request fails" do
    transfers = [
      build_transfer(id: 1, source_currency: "EUR", target_currency: "EUR", target_account: 9999)
    ]
    provider = FakeWiseProvider.new(transfers: transfers, raise_on: { get_balance_statements: "forbidden" })

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").count }, 1 do
      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
    end

    assert result[:success]
    assert_includes provider.calls, :get_transfers
    account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_equal 1, account.raw_transactions_payload.size

    entry = DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").recent.first
    assert_equal "WiseItem::Importer", entry.source
    assert_equal @wise_item.id, entry.metadata["wise_item_id"]
    assert_equal false, entry.metadata["sca_private_key_configured"]
    assert_equal "Provider::Wise::WiseError", entry.metadata["error_class"]
    assert_equal "fetch_failed", entry.metadata["error_type"]
  end

  # A 403 without an SCA challenge means the token cannot read statements:
  # not a failed fetch, one info entry instead of a warning per balance, and
  # the other balances are not asked.
  test "treats statements refused without an SCA challenge as unavailable" do
    provider = two_balances_provider(statements_forbidden)

    result = nil
    assert_no_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").count } do
      assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync", level: "info").count }, 1 do
        result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      end
    end

    assert result[:success]
    assert result[:complete]
    assert_equal 1, provider.calls.count(:get_balance_statements)
    assert_equal [ 1 ], @wise_item.wise_accounts.find_by(currency: "EUR").raw_transactions_payload.map { |t| t["id"] }

    entry = DebugLogEntry.where(provider_key: "wise", category: "provider_sync").recent.first
    assert_equal @wise_item.id, entry.metadata["wise_item_id"]
    assert_equal "access_forbidden", entry.metadata["error_type"]
    assert_equal 2, entry.metadata["balance_count"]
    assert_equal false, entry.metadata["sca_challenged"]
  end

  # A statement 403 that carries Wise's SCA challenge cannot be answered
  # without an SCA key. As for a 403 without one: unavailable this sync,
  # logged once (info) instead of a warning per balance on every sync, no
  # failed fetch, and the other balances are not asked.
  test "treats statements Wise asks to sign as unavailable while no SCA key is configured" do
    provider = two_balances_provider(statements_challenged)

    result = nil
    assert_no_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").count } do
      assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync", level: "info").count }, 1 do
        result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      end
    end

    assert result[:success]
    assert result[:complete]
    assert_equal 1, provider.calls.count(:get_balance_statements)
    assert_equal [ 1 ], @wise_item.wise_accounts.find_by(currency: "EUR").raw_transactions_payload.map { |t| t["id"] }

    entry = DebugLogEntry.where(provider_key: "wise", category: "provider_sync").recent.first
    assert_equal({ "operation" => "balance_statement", "error_type" => "access_forbidden", "balance_count" => 2,
                   "sca_challenged" => true, "sca_private_key_configured" => false },
                 entry.metadata.slice("operation", "error_type", "balance_count", "sca_challenged", "sca_private_key_configured"))
  end

  # With a key configured Provider::Wise answers the challenge with a signed
  # retry, so a challenged 403 is Wise refusing that answer: every balance is
  # asked and warns. It fails nothing, also for a balance that holds
  # statement rows: no later sync would get past it until the key works.
  test "asks every balance and warns when Wise refuses the signed statement requests of a configured SCA key" do
    @wise_item.update_column(:sca_private_key, OpenSSL::PKey::RSA.new(2048).to_pem)
    @wise_item.wise_accounts.create!(
      balance_id: "10000003", name: "Wise GBP", currency: "GBP", raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [ statement_row("CARD-1", "-10.0", "GBP").merge("wise_statement" => true) ]
    )
    provider = two_balances_provider(statements_challenged, more_balances: [ standard_balance("10000003", "GBP", 10.0) ])

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error", level: "warn").count }, 3 do
      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
    end

    assert_equal %w[10000001 10000002 10000003], provider.statement_requests.map { |request| request[:balance_id] }.sort
    assert result[:complete]
    assert_equal 0, result[:fetch_failures]
    assert_empty DebugLogEntry.where(provider_key: "wise", category: "provider_sync").where("metadata ->> 'operation' = ?", "balance_statement")
  end

  # Only the balances without statement rows go unasked once statements prove
  # unavailable; one with statement rows is still asked, and is refused too,
  # which fails nothing. (Balances are read in no fixed order: a refusal of
  # either one leaves the EUR balance unasked or refused.)
  test "still asks a balance with statement rows after statements prove unavailable" do
    @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR", raw_payload: { "type" => "STANDARD" })
    @wise_item.wise_accounts.create!(
      balance_id: "10000002", name: "Wise USD", currency: "USD", raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [ { "wise_statement" => true, "date" => "2026-01-20T10:00:00Z",
                                    "amount" => { "value" => "10.0", "currency" => "USD" }, "referenceNumber" => "CARD-1" } ]
    )
    balances = %w[EUR USD].each_with_index.map do |currency, i|
      { "id" => (10000001 + i).to_s, "amount" => { "value" => 10.0, "currency" => currency }, "type" => "STANDARD" }
    end
    provider = FakeWiseProvider.new(balances: balances, raise_on: { get_balance_statements: statements_forbidden })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_includes provider.statement_requests.map { |request| request[:balance_id] }, "10000002"
    assert result[:complete]
    assert_equal 0, result[:fetch_failures]
    note = DebugLogEntry.where(provider_key: "wise", category: "provider_sync").where("metadata ->> 'operation' = ?", "balance_statement").sole
    assert_equal 2, note.metadata["balance_count"]
  end

  test "a statement failure counts against the import for a balance that holds statement rows" do
    @wise_item.wise_accounts.create!(
      balance_id: "10000001", name: "Wise EUR", currency: "EUR", raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [ { "wise_statement" => true, "date" => "2026-01-20T10:00:00Z",
                                    "amount" => { "value" => "10.0", "currency" => "EUR" }, "referenceNumber" => "CARD-1" } ]
    )
    provider = FakeWiseProvider.new(raise_on: { get_balance_statements: "Unexpected response 502" })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_not result[:success]
    assert_not result[:complete]
    assert_equal 1, result[:fetch_failures]
    assert_equal [ "CARD-1" ], @wise_item.wise_accounts.first.raw_transactions_payload.map { |t| t["referenceNumber"] }
  end

  # A refusal is no outage the next sync gets past: counted as a failure it
  # would keep every import incomplete (no clean-up, anchor repair or
  # replay for any balance) until the token or key changes. It is logged
  # once per sync instead, and the balance keeps its statement rows.
  test "a balance with statement rows whose statements Wise refuses fails nothing" do
    @wise_item.wise_accounts.create!(
      balance_id: "10000001", name: "Wise EUR", currency: "EUR", raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [ statement_row("CARD-1", "-10.0", "EUR", date: "2026-01-20T10:00:00Z").merge("wise_statement" => true) ]
    )

    results = 2.times.map do
      provider = FakeWiseProvider.new(raise_on: { get_balance_statements: statements_forbidden })
      WiseItem::Importer.new(WiseItem.find(@wise_item.id), wise_provider: provider).import
    end

    assert_equal [ [ true, true, 0 ] ] * 2, results.map { |result| result.values_at(:success, :complete, :fetch_failures) }
    assert_equal 2, DebugLogEntry.where(provider_key: "wise", category: "provider_sync", level: "info")
                                 .where("metadata ->> 'operation' = ?", "balance_statement").count
    assert_equal [ "CARD-1" ], @wise_item.wise_accounts.first.raw_transactions_payload.map { |t| t["referenceNumber"] }
  end

  # A balance without statement rows is not covered by statements, so when
  # its statement request fails it takes its transfers and activities like
  # any balance without statements: its rows are stored and coverage moves
  # on for every source, which would otherwise wait as long as the failure
  # lasts and fetch the whole window again on every sync.
  test "a balance without statement rows whose statements fail takes its transfers and activities" do
    balances = [
      {
        "id" => "10000001",
        "amount" => { "value" => 1964.88, "currency" => "EUR" },
        "type" => "STANDARD"
      },
      {
        "id" => "10000002",
        "amount" => { "value" => 500.0, "currency" => "USD" },
        "type" => "STANDARD"
      }
    ]
    payout = build_transfer(id: 77, source_currency: "USD", target_currency: "USD")
    provider = FakeWiseProvider.new(balances: balances, transfers: [ payout ], statement_fail_balance_ids: [ "10000002" ])

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:success]
    assert result[:complete]
    assert_equal 0, result[:transactions_failed]
    assert_includes provider.calls, :get_transfers
    assert_equal [ 77 ], @wise_item.wise_accounts.find_by!(balance_id: "10000002").raw_transactions_payload.map { |row| row["id"] }
    assert_equal %w[activities transfers], @wise_item.reload.raw_payload["coverage"].keys.sort
  end

  test "backfills incoming statement rows into the window already covered by legacy transfers" do
    @wise_item.wise_accounts.create!(
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [
        {
          "id" => 1,
          "sourceCurrency" => "EUR",
          "targetCurrency" => "EUR",
          "sourceValue" => 100.0,
          "targetValue" => 100.0,
          "status" => "outgoing_payment_sent",
          "created" => "2024-01-10"
        }
      ]
    )
    statements = [
      { "date" => "2024-01-15T10:00:00Z", "amount" => { "value" => "-50.00", "currency" => "EUR" }, "referenceNumber" => "st-outgoing-in-window" },
      { "date" => "2024-01-20T10:00:00Z", "amount" => { "value" => "6780.00", "currency" => "EUR" }, "referenceNumber" => "st-incoming-in-window" },
      { "date" => "2024-01-05T10:00:00Z", "amount" => { "value" => "20.00", "currency" => "EUR" }, "referenceNumber" => "st-before-window" }
    ]
    provider = FakeWiseProvider.new(statements: statements)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(currency: "EUR")
    refs = account.raw_transactions_payload.filter_map { |t| t["referenceNumber"] }

    assert_includes refs, "st-incoming-in-window"
    assert_includes refs, "st-before-window"
    refute_includes refs, "st-outgoing-in-window"
  end

  test "keeps an incoming statement row that coincidentally shares its date and amount with a legacy transfer" do
    # A same-day, same-amount external payment must never be dropped just
    # because it looks like it could be the credit leg of a prior internal
    # conversion -- silently losing a real transaction is worse than an
    # occasional visible duplicate (see legacy_overlap_outgoing_row?).
    @wise_item.wise_accounts.create!(
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
      raw_transactions_payload: [
        {
          "id" => 10,
          "targetAccount" => 99999001,
          "sourceCurrency" => "USD",
          "targetCurrency" => "EUR",
          "sourceValue" => 500.0,
          "targetValue" => 450.0,
          "status" => "incoming_payment_received",
          "created" => "2024-02-01"
        }
      ]
    )
    statements = [
      { "date" => "2024-02-01T09:00:00Z", "amount" => { "value" => "450.00", "currency" => "EUR" }, "referenceNumber" => "st-same-date-and-amount" }
    ]
    provider = FakeWiseProvider.new(statements: statements)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(currency: "EUR")
    refs = account.raw_transactions_payload.filter_map { |t| t["referenceNumber"] }

    assert_includes refs, "st-same-date-and-amount"
  end

  test "stops fetching legacy transfers once an account has a successful statement row" do
    @wise_item.wise_accounts.create!(
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [
        {
          "id" => 1,
          "sourceCurrency" => "EUR",
          "targetCurrency" => "EUR",
          "sourceValue" => 100.0,
          "targetValue" => 100.0,
          "status" => "outgoing_payment_sent",
          "created" => "2024-01-10"
        },
        {
          "wise_statement" => true,
          "date" => "2024-01-20",
          "amount" => { "value" => "10.0", "currency" => "EUR" },
          "referenceNumber" => "already-migrated"
        }
      ]
    )
    provider = FakeWiseProvider.new(statements: [])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    refute_includes provider.calls, :get_transfers
  end

  test "does not merge the profile-wide transfer fallback into an account that already migrated to statements" do
    balances = [
      { "id" => "10000001", "amount" => { "value" => 1000.0, "currency" => "EUR" }, "type" => "STANDARD" },
      { "id" => "10000002", "amount" => { "value" => 500.0, "currency" => "USD" }, "type" => "STANDARD" }
    ]
    eur_account = @wise_item.wise_accounts.create!(
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [
        {
          "wise_statement" => true,
          "date" => "2024-01-20",
          "amount" => { "value" => "10.0", "currency" => "EUR" },
          "referenceNumber" => "already-migrated-eur"
        }
      ]
    )
    @wise_item.wise_accounts.create!(
      balance_id: "10000002",
      name: "Wise USD",
      currency: "USD",
      raw_payload: { "type" => "STANDARD" },
      raw_transactions_payload: [
        {
          "id" => 5,
          "sourceCurrency" => "USD",
          "targetCurrency" => "USD",
          "sourceValue" => 20.0,
          "targetValue" => 20.0,
          "status" => "outgoing_payment_sent",
          "created" => "2024-01-05"
        }
      ]
    )
    # USD still needs the legacy fallback, so transfers get fetched profile-wide --
    # including this EUR-currency row, which must not land on the already-migrated
    # EUR account.
    transfers = [ build_transfer(id: 99, source_currency: "EUR", target_currency: "EUR", target_account: 9999) ]
    provider = FakeWiseProvider.new(balances: balances, transfers: transfers, statement_fail_balance_ids: [ "10000002" ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    eur_account.reload
    assert_includes provider.calls, :get_transfers
    refute_includes eur_account.raw_transactions_payload.filter_map { |t| t["id"] }, 99
    assert_includes eur_account.raw_transactions_payload.filter_map { |t| t["referenceNumber"] }, "already-migrated-eur"
  end

  # The incremental window follows the transfers coverage marker (the last
  # successful fetch), not the last completed sync, so a failed fetch can no
  # longer move it. It re-lists 14 days before the marker and always the last
  # 60 days, where a sent payout can still bounce.
  test "keeps the transfer window incremental after a full-history fetch" do
    travel_to Time.utc(2026, 10, 21, 12) do
      @wise_item.update!(import_all_history: true, raw_payload: {
        "coverage" => { "transfers" => { "from" => "2015-01-01T00:00:00Z", "through" => "2026-04-20T00:00:00Z", "version" => WiseItem::COVERAGE_VERSION } }
      })
      provider = FakeWiseProvider.new(raise_on: { get_balance_statements: statements_forbidden })

      WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      WiseItem::Importer.new(@wise_item, wise_provider: provider).import

      starts = provider.transfer_requests.map { |request| request[:created_date_start] }.uniq
      assert_equal [ Time.utc(2026, 4, 6), Time.utc(2026, 8, 22, 12) ], starts
      assert_equal({ "from" => "2015-01-01T00:00:00Z", "through" => "2026-10-21T12:00:00Z", "version" => WiseItem::COVERAGE_VERSION },
                   @wise_item.reload.raw_payload.dig("coverage", "transfers"))
    end
  end

  test "fetches the full history when nothing is covered yet, even with stored rows" do
    travel_to Time.utc(2026, 10, 17, 12) do
      @wise_item.update!(import_all_history: true)
      @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                       raw_payload: { "type" => "STANDARD" },
                                       raw_transactions_payload: [ build_transfer(id: 1) ])
      provider = FakeWiseProvider.new(
        multi_currency_account: { "id" => 77001, "recipientId" => 99999001, "creationTime" => "2024-09-25T10:00:00Z" },
        raise_on: { get_balance_statements: statements_forbidden }
      )

      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

      assert result[:complete]
      # A day before Wise opened the account, which predates every balance.
      full_start = Time.utc(2024, 9, 24, 10)
      assert_equal [ full_start ], provider.transfer_requests.map { |request| request[:created_date_start] }.uniq
      assert_equal [ full_start ], provider.activity_requests.map { |request| request[:since] }
      covered = { "from" => "2024-09-24T10:00:00Z", "through" => "2026-10-17T12:00:00Z", "version" => WiseItem::COVERAGE_VERSION }
      assert_equal({ "transfers" => covered, "activities" => covered }, @wise_item.reload.raw_payload["coverage"])
      assert_equal "2024-09-25T10:00:00Z", @wise_item.raw_payload.dig("multi_currency_account", "creationTime")
    end
  end

  # Coverage that starts after the full history (the item synced the default
  # year first) is widened once import_all_history is switched on.
  test "fetches the full history once import_all_history is enabled after setup" do
    travel_to Time.utc(2026, 10, 17, 12) do
      provider = FakeWiseProvider.new(raise_on: { get_balance_statements: statements_forbidden })
      WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      assert_equal "2025-10-17T12:00:00Z", @wise_item.reload.raw_payload.dig("coverage", "transfers", "from")

      @wise_item.update!(import_all_history: true)
      WiseItem::Importer.new(@wise_item, wise_provider: provider).import

      full_start = Time.utc(2020, 5, 19, 14, 43, 16.658r)
      assert_equal full_start, provider.transfer_requests.last[:created_date_start]
      assert_equal full_start, provider.activity_requests.last[:since]
      assert_equal "2020-05-19T14:43:16Z", @wise_item.reload.raw_payload.dig("coverage", "activities", "from")
    end
  end

  # A sync start date is where the history starts, not where every sync
  # starts, so one inside the covered window leaves the window incremental (it
  # used to fetch from the date on every sync, and a date past the coverage
  # restarted it).
  test "a sync start date inside the covered window leaves the window incremental" do
    travel_to Time.utc(2026, 10, 17, 12) do
      @wise_item.update!(raw_payload: {
        "coverage" => { "activities" => { "from" => "2015-01-01T00:00:00Z", "through" => "2026-10-06T12:00:00Z",
                                          "version" => WiseItem::COVERAGE_VERSION } }
      })
      provider = FakeWiseProvider.new

      WiseItem::Importer.new(@wise_item, wise_provider: provider, sync_start_date: Date.new(2026, 6, 1)).import

      assert_equal Time.utc(2026, 9, 6, 12), provider.activity_requests.first[:since]
      assert_equal "2015-01-01T00:00:00Z", @wise_item.reload.raw_payload.dig("coverage", "activities", "from")
    end
  end

  # The edit form saves a sync start date (prefilled a year back) that used to
  # restart every sync's window there, so each sync paged the whole window
  # again, and with import_all_history the history before it was never
  # fetched. It is where the history starts: fetched once in full (with the
  # full history, from the earlier of it and the account's creation),
  # incrementally afterwards, and once more if moved back.
  test "starts the history at the sync start date and fetches incrementally once it is covered" do
    travel_to Time.utc(2026, 10, 17, 12) do
      @wise_item.update!(sync_start_date: Date.new(2025, 10, 17))
      provider = FakeWiseProvider.new(raise_on: { get_balance_statements: statements_forbidden })
      import = -> { WiseItem::Importer.new(WiseItem.find(@wise_item.id), wise_provider: provider).import }

      2.times { import.call }

      assert_equal [ Time.utc(2025, 10, 17), 60.days.ago ], provider.transfer_requests.map { |request| request[:created_date_start] }
      assert_equal [ Time.utc(2025, 10, 17), 30.days.ago ], provider.activity_requests.map { |request| request[:since] }
      assert_equal "2025-10-17T00:00:00Z", @wise_item.reload.raw_payload.dig("coverage", "activities", "from")

      @wise_item.update!(sync_start_date: Date.new(2025, 6, 1))
      import.call
      assert_equal Time.utc(2025, 6, 1), provider.activity_requests.last[:since]

      @wise_item.update!(import_all_history: true)
      import.call
      assert_equal Time.utc(2020, 5, 19, 14, 43, 16.658r), provider.activity_requests.last[:since]
      import.call
      assert_equal 30.days.ago, provider.activity_requests.last[:since]
    end
  end

  test "re-reads activities back to the oldest stored one that can still change, at most 180 days" do
    travel_to Time.utc(2026, 10, 17, 12) do
      @wise_item.update!(raw_payload: {
        "coverage" => { "activities" => { "from" => "2015-01-01T00:00:00Z", "through" => "2026-10-02T12:00:00Z", "version" => WiseItem::COVERAGE_VERSION } }
      })
      pending = build_interbalance("To <strong>EUR</strong>", resource_id: "8001", primary: "117.50 EUR", secondary: "100 GBP")
                  .merge("status" => "IN_PROGRESS", "createdOn" => "2026-06-17T09:00:00Z")
      eur = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                             raw_payload: { "type" => "STANDARD" },
                                             raw_transactions_payload: [ pending ])
      provider = FakeWiseProvider.new

      WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      assert_equal Time.utc(2026, 6, 16, 9), provider.activity_requests.last[:since]

      eur.update!(raw_transactions_payload: [ pending.merge("createdOn" => "2025-12-02T09:00:00Z") ])
      assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync", level: "info").count }, 1 do
        WiseItem::Importer.new(@wise_item, wise_provider: provider).import
      end
      assert_equal Time.utc(2026, 4, 20, 12), provider.activity_requests.last[:since]
    end
  end

  # Activity routing

  test "routes INTERBALANCE activities to both JAR and STANDARD accounts" do
    savings = {
      "id" => "10000002",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }
    interbalance = build_interbalance("To <strong>Jar</strong>", resource_id: "5001")
    provider = FakeWiseProvider.new(savings_balances: [ savings ], activities: [ interbalance ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    jar = @wise_item.wise_accounts.find_by(balance_id: "10000002")
    standard = @wise_item.wise_accounts.find_by(balance_id: "10000001")

    assert_equal 1, jar.raw_transactions_payload.size
    assert jar.raw_transactions_payload.any? { |a| a["type"] == "INTERBALANCE" }
    assert standard.raw_transactions_payload.any? { |a| a["type"] == "INTERBALANCE" }
  end

  test "routes currency conversions only to the source and target STANDARD balances" do
    balances = %w[GBP EUR CHF USD].each_with_index.map do |currency, i|
      {
        "id" => "2000000#{i}",
        "amount" => { "value" => 100.0, "currency" => currency },
        "reservedAmount" => { "value" => 0.0, "currency" => currency },
        "type" => "STANDARD"
      }
    end
    gbp_to_eur = build_interbalance("To <strong>EUR</strong>", resource_id: "7001",
                                    primary: "117.50 EUR", secondary: "100 GBP")
    usd_to_chf = build_interbalance("To <strong>CHF</strong>", resource_id: "7002",
                                    primary: "1,345.20 CHF", secondary: "1,500 USD")
    provider = FakeWiseProvider.new(balances: balances, activities: [ gbp_to_eur, usd_to_chf ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    routed = @wise_item.wise_accounts.to_h do |wise_account|
      [ wise_account.currency, wise_account.raw_transactions_payload.map { |a| a["id"] } ]
    end

    assert_equal [ "interbalance_7001" ], routed["GBP"]
    assert_equal [ "interbalance_7001" ], routed["EUR"]
    assert_equal [ "interbalance_7002" ], routed["CHF"]
    assert_equal [ "interbalance_7002" ], routed["USD"]
  end

  test "drops previously stored conversions that do not involve the STANDARD balance" do
    balances = [
      { "id" => "20000001", "amount" => { "value" => 100.0, "currency" => "GBP" }, "type" => "STANDARD" }
    ]
    own = build_interbalance("To <strong>EUR</strong>", resource_id: "7005", primary: "117.50 EUR", secondary: "100 GBP")
    other = build_interbalance("To <strong>CHF</strong>", resource_id: "7006", primary: "1,345.20 CHF", secondary: "1,500 USD")
    transfer = build_transfer(id: 4242, source_currency: "GBP", target_currency: "GBP")
    gbp = @wise_item.wise_accounts.create!(balance_id: "20000001", currency: "GBP", name: "Wise GBP",
                                           raw_payload: { "type" => "STANDARD" },
                                           raw_transactions_payload: [ transfer, own, other ])
    provider = FakeWiseProvider.new(balances: balances, transfers: [ transfer ], activities: [])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal [ 4242, "interbalance_7005" ], gbp.reload.raw_transactions_payload.map { |t| t["id"] }
  end

  test "routes a cross-currency JAR move to the source STANDARD balance but not the jar-currency one" do
    balances = [
      { "id" => "20000001", "amount" => { "value" => 100.0, "currency" => "GBP" }, "type" => "STANDARD" },
      { "id" => "20000002", "amount" => { "value" => 100.0, "currency" => "EUR" }, "type" => "STANDARD" }
    ]
    savings = {
      "id" => "20000003",
      "amount" => { "value" => 0.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Holiday"
    }
    move = build_interbalance("To <strong>Holiday</strong>", resource_id: "7003",
                              primary: "117.50 EUR", secondary: "100 GBP")
    provider = FakeWiseProvider.new(balances: balances, savings_balances: [ savings ], activities: [ move ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal 1, @wise_item.wise_accounts.find_by(balance_id: "20000001").raw_transactions_payload.size
    assert_empty Array(@wise_item.wise_accounts.find_by(balance_id: "20000002").raw_transactions_payload)
    assert_equal 1, @wise_item.wise_accounts.find_by(balance_id: "20000003").raw_transactions_payload.size
  end

  test "does not route a same-currency JAR move to a STANDARD balance in another currency" do
    balances = [
      { "id" => "20000001", "amount" => { "value" => 100.0, "currency" => "GBP" }, "type" => "STANDARD" },
      { "id" => "20000002", "amount" => { "value" => 100.0, "currency" => "EUR" }, "type" => "STANDARD" }
    ]
    move = build_interbalance("To <strong>Jar</strong>", resource_id: "7004")
    provider = FakeWiseProvider.new(balances: balances, activities: [ move ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_empty Array(@wise_item.wise_accounts.find_by(balance_id: "20000001").raw_transactions_payload)
    assert_equal 1, @wise_item.wise_accounts.find_by(balance_id: "20000002").raw_transactions_payload.size
  end

  test "routes BALANCE_CASHBACK only to JAR account" do
    savings = {
      "id" => "10000002",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }
    cashback = build_cashback("57001")
    provider = FakeWiseProvider.new(savings_balances: [ savings ], activities: [ cashback ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    jar = @wise_item.wise_accounts.find_by(balance_id: "10000002")
    standard = @wise_item.wise_accounts.find_by(balance_id: "10000001")

    assert_equal 1, jar.raw_transactions_payload.size
    assert_empty standard.raw_transactions_payload.select { |a| a["type"] == "BALANCE_CASHBACK" }
  end

  # A repeated cursor means Wise ignored it and the feed was not read to the
  # end, so the fetch now fails the import and its pages are dropped instead
  # of passing for the complete history.
  test "stops activity pagination and fails the fetch when Wise repeats a cursor" do
    activity = build_interbalance("To <strong>Jar</strong>", resource_id: "5001")
    provider = FakeWiseProvider.new
    provider.define_singleton_method(:get_activities) do |_profile_id, size: 100, **|
      calls << :get_activities
      { "activities" => Array.new(size, activity), "cursor" => "repeated-cursor" }
    end

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal 2, provider.calls.count(:get_activities)
    assert_not result[:success]
    assert_not result[:complete]
    assert_equal 1, result[:fetch_failures]
    assert_empty Array(@wise_item.wise_accounts.first.raw_transactions_payload)
    assert_nil @wise_item.reload.raw_payload.dig("coverage", "activities")
  end

  test "follows nextCursor until Wise returns no cursor" do
    to_eur = build_interbalance("To <strong>EUR</strong>", resource_id: "7001", primary: "117.50 EUR", secondary: "100 GBP")
    from_eur = build_interbalance("To <strong>GBP</strong>", resource_id: "7002", primary: "86.10 GBP", secondary: "100 EUR")
    pages = { nil => { "activities" => [ to_eur ], "cursor" => "page-2" },
              "page-2" => { "activities" => [ from_eur ], "cursor" => nil } }
    provider = FakeWiseProvider.new(activity_pages: pages)

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:complete]
    assert_equal [ nil, "page-2" ], provider.activity_requests.map { |request| request[:cursor] }
    assert_equal %w[interbalance_7001 interbalance_7002],
                 @wise_item.wise_accounts.first.raw_transactions_payload.map { |a| a["id"] }.sort
  end

  # One 5xx answer on a later page no longer drops the pages already read.
  test "asks again for a page Wise answered with a server error" do
    to_eur = build_interbalance("To <strong>EUR</strong>", resource_id: "7001", primary: "117.50 EUR", secondary: "100 GBP")
    from_eur = build_interbalance("To <strong>GBP</strong>", resource_id: "7002", primary: "86.10 GBP", secondary: "100 EUR")
    pages = { nil => { "activities" => [ to_eur ], "cursor" => "page-2" },
              "page-2" => { "activities" => [ from_eur ], "cursor" => nil } }
    provider = FakeWiseProvider.new(activity_pages: pages, raise_on: { get_balance_statements: statements_forbidden })
    failed_once = false
    provider.define_singleton_method(:get_activities) do |*args, cursor: nil, **options|
      if cursor == "page-2" && !failed_once
        failed_once = true
        raise Provider::Wise::WiseError.new("Unexpected response 502: Bad Gateway", :server_error)
      end
      super(*args, cursor: cursor, **options)
    end
    Provider::Wise.expects(:sleep).once

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:complete]
    assert failed_once
    assert_equal [ nil, "page-2" ], provider.activity_requests.map { |request| request[:cursor] }
    assert_equal %w[interbalance_7001 interbalance_7002], payload_ids["10000001"]
  end

  # Wise lists transfers oldest first, so stopping at the first old one never
  # reached newer pages. The third page starts at 200, not after the 101 rows
  # received (Wise refuses offset 101, see below).
  test "fetches every page of Wise's oldest-first transfer list" do
    old = (1..100).map do |i|
      build_transfer(id: i).merge("created" => (400.days.ago + i.minutes).utc.strftime("%Y-%m-%d %H:%M:%S"))
    end
    recent = build_transfer(id: 101).merge("created" => 1.day.ago.utc.strftime("%Y-%m-%d %H:%M:%S"))
    provider = FakeWiseProvider.new(transfers: old + [ recent ], raise_on: { get_balance_statements: statements_forbidden })

    WiseItem::Importer.new(@wise_item, wise_provider: provider, sync_start_date: 30.days.ago.to_date).import

    assert_equal [ 0, 100, 200 ], provider.transfer_requests.map { |request| request[:offset] }
    assert_includes @wise_item.wise_accounts.first.raw_transactions_payload.map { |t| t["id"] }, 101
  end

  # Wise takes an offset only as a multiple of the limit: any other offset
  # gets HTTP 422 inconsistent.pagination, and one past the last row an empty
  # page. Paging on by the rows received failed the transfer list every sync,
  # so no import was complete and no transfers coverage was ever written.
  test "asks for each transfer page at a multiple of the page size" do
    provider = FakeWiseProvider.new(transfers: (1..47).map { |id| build_transfer(id: id) },
                                    raise_on: { get_balance_statements: statements_forbidden })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal [ [ 0, 100 ], [ 100, 100 ] ], provider.transfer_requests.map { |request| request.values_at(:offset, :limit) }
    assert result[:complete]
    assert_equal 0, result[:fetch_failures]
    assert_equal (1..47).to_a, payload_ids["10000001"]
    assert_not_nil @wise_item.reload.fetch_coverage(:transfers)
  end

  test "reads a transfer list of several pages up to the empty page after the last" do
    provider = FakeWiseProvider.new(transfers: (1..230).map { |id| build_transfer(id: id) },
                                    raise_on: { get_balance_statements: statements_forbidden })

    assert WiseItem::Importer.new(@wise_item, wise_provider: provider).import[:complete]

    assert_equal [ 0, 100, 200, 300 ], provider.transfer_requests.map { |request| request[:offset] }
    assert_equal (1..230).to_a, payload_ids["10000001"]
  end

  # A page may hold fewer transfers than the limit without being the last
  # (a server cap or filter): only an empty page ends the list, and the next
  # page still starts a page size on, the only offset Wise takes.
  test "follows a transfer page shorter than the limit with the next page" do
    pages = { 0 => (1..60).map { |id| build_transfer(id: id) }, 100 => (61..100).map { |id| build_transfer(id: id) } }
    provider = FakeWiseProvider.new(transfer_pages: pages, raise_on: { get_balance_statements: statements_forbidden })

    assert WiseItem::Importer.new(@wise_item, wise_provider: provider).import[:complete]

    assert_equal [ 0, 100, 200 ], provider.transfer_requests.map { |request| request[:offset] }
    assert_equal (1..100).to_a, payload_ids["10000001"]
  end

  test "waits for Wise's Retry-After before retrying a rate-limited transfers page" do
    provider = FakeWiseProvider.new(transfers: [ build_transfer(id: 1) ],
                                    raise_on: { get_balance_statements: statements_forbidden })
    limited = true
    provider.define_singleton_method(:get_transfers) do |*args, **options|
      if limited
        limited = false
        raise Provider::Wise::WiseError.new("Rate limit exceeded", :rate_limited, retry_after: 7)
      end
      super(*args, **options)
    end
    Provider::Wise.expects(:sleep).with { |seconds| seconds >= 7 && seconds < 8 }.once

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:success]
    assert_equal [ 1 ], @wise_item.wise_accounts.first.raw_transactions_payload.map { |t| t["id"] }
  end

  test "a failed activities fetch keeps payloads and coverage, and the next sync resumes from them" do
    travel_to Time.utc(2026, 10, 17, 12) do
      coverage = { "activities" => { "from" => "2015-01-01T00:00:00Z", "through" => "2026-10-01T00:00:00Z", "version" => WiseItem::COVERAGE_VERSION } }
      @wise_item.update!(raw_payload: { "coverage" => coverage })
      stored = build_interbalance("To <strong>EUR</strong>", resource_id: "7001", primary: "117.50 EUR", secondary: "100 GBP")
      eur = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                             raw_payload: { "type" => "STANDARD" }, raw_transactions_payload: [ stored ])
      failing = FakeWiseProvider.new(raise_on: { get_activities: "Unexpected response 502" })

      result = nil
      assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").count }, 1 do
        result = WiseItem::Importer.new(@wise_item, wise_provider: failing).import
      end

      assert_not result[:success]
      assert_not result[:complete]
      assert_equal 1, result[:fetch_failures]
      assert_equal [ stored ], eur.reload.raw_transactions_payload
      assert_equal coverage, @wise_item.reload.raw_payload["coverage"]

      later = build_interbalance("To <strong>GBP</strong>", resource_id: "7002", primary: "86.10 GBP", secondary: "100 EUR")
      recovered = FakeWiseProvider.new(activities: [ later ])
      assert WiseItem::Importer.new(@wise_item, wise_provider: recovered).import[:complete]

      assert_equal Time.utc(2026, 9, 1), recovered.activity_requests.first[:since]
      assert_equal %w[interbalance_7001 interbalance_7002], eur.reload.raw_transactions_payload.map { |a| a["id"] }
    end
  end

  # A failed first-sync transfer list used to report success and move the
  # window past the transfers it never fetched.
  test "a failed transfers fetch is retried from the full window on the next sync" do
    travel_to Time.utc(2026, 10, 17, 12) do
      failing = FakeWiseProvider.new(raise_on: { get_transfers: "Connection failed: Net::ReadTimeout",
                                                 get_balance_statements: statements_forbidden })
      result = WiseItem::Importer.new(@wise_item, wise_provider: failing).import

      assert_not result[:success]
      assert_equal 1, result[:fetch_failures]
      assert_nil @wise_item.reload.raw_payload.dig("coverage", "transfers")

      history = build_transfer(id: 5).merge("created" => 90.days.ago.utc.strftime("%Y-%m-%d %H:%M:%S"))
      recovered = FakeWiseProvider.new(transfers: [ history ], raise_on: { get_balance_statements: statements_forbidden })
      WiseItem::Importer.new(@wise_item, wise_provider: recovered).import

      assert_equal 365.days.ago, recovered.transfer_requests.first[:created_date_start]
      assert_equal [ 5 ], @wise_item.wise_accounts.first.raw_transactions_payload.map { |t| t["id"] }
    end
  end

  test "re-reads stored transfers that can still change, newest first" do
    older = build_transfer(id: 21).merge("status" => "processing", "created" => "2025-08-26 10:00:00")
    newer = build_transfer(id: 22).merge("status" => "incoming_payment_waiting", "created" => "2025-11-18 10:00:00")
    sent = build_transfer(id: 23)
    cancelled = build_transfer(id: 24).merge("status" => "cancelled")
    eur = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                           raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
                                           raw_transactions_payload: [ older, newer, sent, cancelled ])
    provider = FakeWiseProvider.new(
      transfer_details: { "21" => older.merge("status" => "funds_refunded"), "22" => newer.merge("status" => "cancelled") },
      raise_on: { get_balance_statements: statements_forbidden }
    )

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:complete]
    assert_equal [ 22, 21 ], provider.transfer_reads
    statuses = eur.reload.raw_transactions_payload.to_h { |t| [ t["id"], t["status"] ] }
    assert_equal({ 21 => "funds_refunded", 22 => "cancelled", 23 => "outgoing_payment_sent", 24 => "cancelled" }, statuses)
  end

  test "re-reads at most 50 transfers per sync" do
    rows = (1..51).map { |i| build_transfer(id: i).merge("status" => "processing", "created" => "2025-07-22 10:#{format('%02d', i)}:00") }
    @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                     raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
                                     raw_transactions_payload: rows)
    provider = FakeWiseProvider.new(transfer_details: rows.index_by { |row| row["id"].to_s },
                                    raise_on: { get_balance_statements: statements_forbidden })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal (2..51).to_a.reverse, provider.transfer_reads
  end

  # Re-reads refresh stored rows, not the listed window, so the window still
  # counts as covered.
  test "a failed transfer re-read fails the import and keeps the stored copy" do
    travel_to Time.utc(2026, 10, 17, 12) do
      processing = build_transfer(id: 31).merge("status" => "processing")
      eur = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                             raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
                                             raw_transactions_payload: [ processing ])
      provider = FakeWiseProvider.new(raise_on: { get_transfer: "Unexpected response 503",
                                                  get_balance_statements: statements_forbidden })

      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

      assert_not result[:complete]
      assert_equal 1, result[:fetch_failures]
      assert_equal [ processing ], eur.reload.raw_transactions_payload
      assert_equal "2026-10-17T12:00:00Z", @wise_item.reload.raw_payload.dig("coverage", "transfers", "through")
    end
  end

  # A transfer Wise no longer finds is no failed fetch (one vanished transfer
  # would keep every import incomplete); its stored copy stays, and support is
  # told how many once. It is read again on three syncs, then no more, unless
  # Wise lists it again.
  test "a transfer Wise no longer finds keeps its stored copy and fails nothing" do
    processing = build_transfer(id: 41).merge("status" => "processing")
    eur = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                           raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 },
                                           raw_transactions_payload: [ processing ])
    import = lambda do |**options|
      provider = FakeWiseProvider.new(raise_on: { get_balance_statements: statements_forbidden }, **options)
      [ WiseItem::Importer.new(WiseItem.find(@wise_item.id), wise_provider: provider).import, provider ]
    end

    result, provider = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error", level: "warn").count }, 1 do
      result, provider = import.call
    end

    assert result[:success]
    assert result[:complete]
    assert_equal [ 41 ], provider.transfer_reads
    assert_equal [ processing.merge("wise_missing_count" => 1) ], eur.reload.raw_transactions_payload
    note = DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").sole
    assert_equal [ "transfer", 1 ], note.metadata.values_at("operation", "missing_transfer_count")
    assert @wise_item.reload.raw_payload.dig("coverage", "transfers")

    reads = 3.times.map { import.call.last.transfer_reads }
    assert_equal [ [ 41 ], [ 41 ], [] ], reads
    assert_equal 1, DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error").count
    assert_equal 3, eur.reload.raw_transactions_payload.sole["wise_missing_count"]

    import.call(transfers: [ processing.merge("status" => "outgoing_payment_sent") ])
    assert_equal [ processing.merge("status" => "outgoing_payment_sent") ], eur.reload.raw_transactions_payload
  end

  # A jar is linked after the first sync, so its payload must keep what
  # earlier syncs fetched.
  test "keeps a jar's stored moves when a later fetch returns fewer rows or fails" do
    savings = {
      "id" => "10000002", "type" => "SAVINGS", "name" => "Holiday",
      "amount" => { "value" => 1200.0, "currency" => "EUR" }, "totalWorth" => { "value" => 1200.0, "currency" => "EUR" }
    }
    deposit = build_interbalance("To <strong>Holiday</strong>", resource_id: "5001")

    WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new(savings_balances: [ savings ], activities: [ deposit ])).import
    jar = @wise_item.wise_accounts.find_by!(balance_id: "10000002")
    assert_equal [ "interbalance_5001" ], jar.raw_transactions_payload.map { |a| a["id"] }

    WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new(savings_balances: [ savings ])).import
    assert_equal [ "interbalance_5001" ], jar.reload.raw_transactions_payload.map { |a| a["id"] }

    failing = FakeWiseProvider.new(savings_balances: [ savings ], raise_on: { get_activities: "Unexpected response 503" })
    WiseItem::Importer.new(@wise_item, wise_provider: failing).import
    assert_equal [ "interbalance_5001" ], jar.reload.raw_transactions_payload.map { |a| a["id"] }
  end

  test "takes the account recipient from the multi-currency account" do
    provider = FakeWiseProvider.new(borderless_accounts: [],
                                    multi_currency_account: { "id" => 5, "recipientId" => 12345678, "creationTime" => "2025-06-11T10:00:00Z" })

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_equal 12345678, @wise_item.wise_accounts.first.raw_payload["recipient_id"]
    assert_equal({ "id" => 5, "recipientId" => 12345678, "creationTime" => "2025-06-11T10:00:00Z" },
                 @wise_item.reload.raw_payload["multi_currency_account"])
  end

  # A failed lookup of the multi-currency account must not move the full
  # history to FULL_HISTORY_START_DATE: the creationTime the item keeps from
  # an earlier lookup still dates it.
  test "starts the full history from the stored account creation when the lookup fails" do
    travel_to Time.utc(2026, 10, 17, 12) do
      @wise_item.update!(import_all_history: true,
                         raw_payload: { "multi_currency_account" => { "creationTime" => "2024-11-27T10:00:00Z" } })
      provider = FakeWiseProvider.new(raise_on: { get_multi_currency_account: "Unexpected response 502",
                                                  get_balance_statements: statements_forbidden })

      WiseItem::Importer.new(@wise_item, wise_provider: provider).import

      assert_equal [ Time.utc(2024, 11, 26, 10) ], provider.transfer_requests.map { |request| request[:created_date_start] }.uniq
      assert_equal [ Time.utc(2024, 11, 26, 10) ], provider.activity_requests.map { |request| request[:since] }
      assert_equal "2024-11-27T10:00:00Z", @wise_item.reload.raw_payload.dig("multi_currency_account", "creationTime")
    end
  end

  test "keeps stored recipient ids when the account lookups fail" do
    eur = @wise_item.wise_accounts.create!(
      balance_id: "10000001", name: "Wise EUR", currency: "EUR",
      raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001, "borderless_account_id" => 88888001, "recipientId" => 77777001 }
    )
    provider = FakeWiseProvider.new(raise_on: { get_multi_currency_account: "Unexpected response 502",
                                                get_borderless_accounts: "Unexpected response 502" })

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "wise", category: "provider_sync_error", level: "warn").count }, 2 do
      result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import
    end

    assert result[:success]
    assert result[:complete]
    assert_equal [ 99999001, 88888001, 77777001 ], eur.reload.raw_payload.values_at("recipient_id", "borderless_account_id", "recipientId")
  end

  test "tracks whether both balance lists arrived in full" do
    complete = WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new)
    complete.import
    assert complete.send(:balance_lists_complete?)

    [ { get_savings_balances: "Unexpected response 500" },
      { get_savings_balances: Provider::Wise::WiseError.new("Resource not found", :not_found) },
      { get_balances: Provider::Wise::WiseError.new("Resource not found", :not_found) } ].each do |raise_on|
      importer = WiseItem::Importer.new(@wise_item, wise_provider: FakeWiseProvider.new(raise_on: raise_on))
      found_nothing = raise_on.values.first.is_a?(Provider::Wise::WiseError)
      assert_equal found_nothing, importer.import[:complete], "only a list Wise says is empty completes (#{raise_on.inspect})"
      assert_not importer.send(:balance_lists_complete?), raise_on.keys.first
    end
  end

  # Returns failed result when balances fetch fails

  test "returns failed result when STANDARD balances fetch fails" do
    provider = FakeWiseProvider.new(raise_on: { get_balances: "server error" })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_not result[:success]
    assert_equal "Failed to fetch balances", result[:error]
  end

  private

    # A statement 403 without an SCA challenge: the token may not read
    # statements at all.
    def statements_forbidden
      Provider::Wise::WiseError.new("Access forbidden — check token permissions", :access_forbidden)
    end

    # What a token Wise asks for SCA gets for every statement without an SCA
    # key: 403 with Wise's SCA challenge, which Sure cannot sign. With a key,
    # what Wise answers to the signed retry.
    def statements_challenged
      Provider::Wise::WiseError.new("Access forbidden — check token permissions", :access_forbidden, sca_challenged: true)
    end

    # EUR and USD balances without statement rows (and more_balances), whose
    # statement requests all raise statement_error, and one EUR payout.
    def two_balances_provider(statement_error, more_balances: [])
      balances = %w[EUR USD].each_with_index.map do |currency, i|
        { "id" => (10000001 + i).to_s, "amount" => { "value" => 10.0, "currency" => currency }, "type" => "STANDARD" }
      end
      borderless = [ { "id" => 88888001, "recipientId" => 99999001,
                       "balances" => [ { "id" => 10000001 }, { "id" => 10000002 } ] } ]
      transfers = [ build_transfer(id: 1, source_currency: "EUR", target_currency: "EUR", target_account: 9999) ]
      FakeWiseProvider.new(balances: balances + more_balances, borderless_accounts: borderless, transfers: transfers,
                           raise_on: { get_balance_statements: statement_error })
    end

    def build_transfer(id:, source_currency: "EUR", target_currency: "EUR", target_account: 9999)
      {
        "id" => id,
        "targetAccount" => target_account,
        "sourceCurrency" => source_currency,
        "targetCurrency" => target_currency,
        "sourceValue" => 100.0,
        "targetValue" => 100.0,
        "status" => "outgoing_payment_sent",
        "created" => 7.days.ago.strftime("%Y-%m-%d %H:%M:%S")
      }
    end

    def build_interbalance(title, resource_id:, primary: "1,000 EUR", secondary: nil)
      {
        "id" => "interbalance_#{resource_id}",
        "type" => "INTERBALANCE",
        "resource" => { "type" => "BALANCE_TRANSACTION", "id" => resource_id },
        "title" => title,
        "primaryAmount" => primary,
        "secondaryAmount" => secondary,
        "status" => "COMPLETED",
        "createdOn" => 7.days.ago.iso8601
      }.compact
    end

    def statement_row(reference, value, currency, date: 2.days.ago.utc.iso8601)
      { "type" => value.to_d.negative? ? "DEBIT" : "CREDIT", "date" => date,
        "amount" => { "value" => value, "currency" => currency }, "details" => { "type" => "CARD" },
        "referenceNumber" => reference }
    end

    def standard_balance(id, currency, value)
      { "id" => id, "type" => "STANDARD", "amount" => { "value" => value, "currency" => currency },
        "reservedAmount" => { "value" => 0.0, "currency" => currency } }
    end

    def eur_balance(id, value)
      standard_balance(id, "EUR", value)
    end

    # { balance id => sorted ids of the rows stored on it }.
    def payload_ids
      @wise_item.wise_accounts.reload.to_h do |wise_account|
        [ wise_account.balance_id, Array(wise_account.raw_transactions_payload).map { |row| row["id"] }.sort ]
      end
    end

    def build_cashback(resource_id)
      {
        "id" => "cashback_#{resource_id}",
        "type" => "BALANCE_CASHBACK",
        "resource" => { "type" => "BALANCE_CASHBACK", "id" => resource_id },
        "title" => "<strong>Cashback</strong>",
        "primaryAmount" => "<positive>+ 1.12 EUR</positive>",
        "status" => "COMPLETED",
        "createdOn" => 3.days.ago.iso8601
      }
    end
end
