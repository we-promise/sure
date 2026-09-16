require "test_helper"
require_relative "../../../../support/enable_banking_migration_test_helper"

class Provider::AccountData::EnableBanking::CutoverHistoryTest < ActiveSupport::TestCase
  include EnableBankingMigrationTestHelper
  self.use_transactional_tests = false

  History = Provider::AccountData::EnableBanking::CutoverHistory
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    Sentry.stubs(:capture_exception)
    Provider::EnableBanking.expects(:new).never
    Account.any_instance.stubs(:sync_later)
    clear_enqueued_jobs
  end
  teardown { clear_enqueued_jobs }

  test "empty and nil caches request full history without converting a successful Sync or consent expiry into coverage" do
    [ [], nil ].each do |rows|
      with_enable_banking_migration_source(rows: rows) do |context|
        context.item.syncs.create!(status: "completed", completed_at: 1.day.ago)
        before = retained_state(context)
        result = nil
        queries = capture_sql_queries { result = verify_result(context) }

        assert_equal({ context.external.id => nil }, result.account_starts)
        assert result.frozen?
        assert result.account_starts.frozen?
        assert_equal before, retained_state(context)
        assert_empty queries.grep(/\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b/i)
        assert context.connection.provider_sync_checkpoints.all? { |checkpoint| checkpoint.covered_through.nil? }
      end
    end
  end

  test "real legacy posting and signed proof preserve the original transaction UUIDs" do
    with_enable_banking_migration_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      ids = [ entry.id, entry.entryable_id ]
      before = retained_state(context)

      assert_nil verify_history(context)

      assert_equal ids, [ entry.reload.id, entry.entryable_id ]
      assert_equal "enable_banking_retained-transaction", entry.external_id
      assert_equal BigDecimal("12.34"), entry.amount
      assert_equal "EUR", entry.currency
      assert_equal "Retained reference\n\nOriginal note", entry.notes
      assert_equal before, retained_state(context)
    end
  end

  test "exact idless legacy decimal fingerprints are usable without inventing a new identity" do
    raw = transaction.except("transaction_id").merge("transaction_amount" => { "amount" => 12.34, "currency" => "EUR" })
    with_enable_banking_migration_source(rows: [ raw ]) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      expected = EnableBankingEntry::Processor.compute_external_id(raw)
      before = retained_state(context)

      assert_nil verify_history(context)
      assert_equal expected, entry.reload.external_id
      assert_match(/\Aenable_banking_content_[0-9a-f]{32}\z/, expected)
      assert_equal before, retained_state(context)
    end
  end

  test "the explicit item start remains the floor even when signed cached transactions are older" do
    start = Date.new(2026, 8, 1)
    with_enable_banking_migration_source(rows: [ transaction ], item_attributes: { sync_start_date: start }) do |context|
      publish_identities(context)
      before = retained_state(context)
      result = verify_result(context)

      assert_equal({ context.external.id => start }, result.account_starts)
      assert result.account_starts.fetch(context.external.id).frozen?
      assert_equal start, context.connection.sync_start_date
      assert_equal before, retained_state(context)
    end
  end

  test "post-bootstrap user edits and protections do not rewrite the original signed cache baseline" do
    with_enable_banking_migration_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      entry = context.account.entries.sole
      entry.update!(name: "User name", notes: "User note", amount: 99, date: Date.new(2020, 1, 8),
        user_modified: true, import_locked: true,
        locked_attributes: { "name" => true, "notes" => true, "amount" => true, "date" => true })
      before = retained_state(context)

      assert_nil verify_history(context)
      assert_equal before, retained_state(context)
    end
  end

  test "current pending state must still match the signed original pending identity" do
    with_enable_banking_migration_source(rows: [ transaction("status" => "PDNG", "_pending" => true) ]) do |context|
      publish_identities(context)
      assert_nil verify_history(context)
      entry = context.account.entries.sole
      entry.transaction.update!(extra: entry.transaction.extra.deep_merge("enable_banking" => { "pending" => false }))
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "a PDNG row imported without the legacy pending marker cannot be certified as its booked baseline" do
    with_enable_banking_migration_source(rows: [ transaction("status" => "PDNG") ]) do |context|
      publish_identities(context)
      refute context.account.entries.sole.transaction.pending?
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "signed retired pending aliases are dispositions while a cached posted alias still refuses" do
    [ true, false ].each do |pending|
      alias_raw = transaction("_pending" => pending, "status" => pending ? "PDNG" : "BOOK")
      create_posted = lambda do |_item, source, account|
        EnableBankingEntry::Processor.new(transaction("transaction_id" => "current-booked"), enable_banking_account: source).process
        entry = account.entries.sole
        entry.transaction.update!(extra: (entry.transaction.extra || {}).merge("auto_claimed_pending_ids" => [ "enable_banking_retained-transaction" ]))
      end
      with_enable_banking_migration_source(rows: [ alias_raw ], import: false, before_copy: create_posted) do |context|
        publish_identities(context)
        before = retained_state(context)

        if pending
          assert_nil verify_history(context)
        else
          assert_raises(History::Conflict) { verify_history(context) }
        end

        assert_equal "enable_banking_current-booked", context.account.entries.sole.external_id
        assert_equal before, retained_state(context)
      end
    end
  end

  test "manual merge suppression without a signed alias cannot certify a missing cached pending identity" do
    create_posted = lambda do |_item, source, account|
      EnableBankingEntry::Processor.new(transaction("transaction_id" => "manually-kept"), enable_banking_account: source).process
      entry = account.entries.sole
      entry.transaction.update!(extra: (entry.transaction.extra || {}).merge("manual_merge" => [
        { "merged_from_external_id" => "enable_banking_retained-transaction" }
      ]))
    end
    with_enable_banking_migration_source(rows: [ transaction("_pending" => true, "status" => "PDNG") ],
      import: false, before_copy: create_posted) do |context|
      publish_identities(context)
      assert_equal [ "enable_banking_manually-kept" ], SourceRecord.where(external_account: context.external).pluck(:external_id)
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "an empty copied cache does not withdraw a previously imported pending transaction" do
    create_pending = lambda do |_item, source, _account|
      EnableBankingEntry::Processor.new(transaction("_pending" => true, "status" => "PDNG"), enable_banking_account: source).process
    end
    with_enable_banking_migration_source(rows: [], before_copy: create_pending) do |context|
      publish_identities(context)
      before = retained_state(context)

      assert_nil verify_history(context)
      assert context.account.entries.sole.transaction.pending?
      refute SourceRecord.where(external_account: context.external).sole.withdrawn?
      assert_equal before, retained_state(context)
    end
  end

  test "unapplied cached transactions and financial identities owned by another account are not accepted" do
    [ false, true ].each do |foreign_financial|
      with_enable_banking_migration_source(rows: [ transaction ], import: false) do |context|
        if foreign_financial
          other = context.family.accounts.create!(name: "Other account", currency: "EUR", balance: 0, accountable: Depository.new)
          other.entries.create!(name: "Retained reference", date: Date.new(2020, 1, 2), amount: 12.34, currency: "EUR",
            source: "enable_banking", external_id: "enable_banking_retained-transaction", entryable: Transaction.new)
        end
        publish_identities(context)
        before = retained_state(context)

        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "an existing legacy Entry alone cannot substitute for its missing signed bootstrap proof" do
    with_enable_banking_migration_source(rows: [ transaction ]) do |context|
      assert_equal 1, context.account.entries.count
      assert_empty SourceRecord.where(external_account: context.external)
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "unknown cache shapes and malformed dates or money refuse without importing a zero or partial record" do
    invalid = [ {}, "unknown", [ nil ], [ {} ],
      [ transaction.except("booking_date") ], [ transaction.except("transaction_amount") ],
      [ transaction("transaction_amount" => { "amount" => "invalid", "currency" => "EUR" }) ] ]
    invalid.each do |rows|
      with_enable_banking_migration_source(rows: rows, import: false) do |context|
        publish_identities(context)
        before = retained_state(context)

        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
        assert_empty context.account.entries
      end
    end
  end

  test "duplicate cache identities refuse even when legacy upsert produced a single financial row" do
    with_enable_banking_migration_source(rows: [ transaction, transaction ]) do |context|
      publish_identities(context)
      assert_equal 1, context.account.entries.count
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "a cache changed after its archive refuses without rewriting the original archive" do
    with_enable_banking_migration_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      context.source.update!(raw_transactions_payload: [ transaction("note" => "Unapplied new note") ])
      before = retained_state(context)

      assert_raises(History::Conflict) { verify_history(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "a freshly copied cache revision still needs matching signed original financial values" do
    changes = [ { "transaction_amount" => { "amount" => "99.00", "currency" => "EUR" } },
      { "booking_date" => "2020-02-03" }, { "note" => "Unapplied note" },
      { "exchange_rate" => { "exchange_rate" => "1.2", "unit_currency" => "USD", "instructed_amount" => { "amount" => "15" } } },
      { "merchant_category_code" => "5411" } ]
    changes.each do |change|
      alter_cache = ->(_item, source, _account) { source.update!(raw_transactions_payload: [ transaction(change) ]) }
      with_enable_banking_migration_source(rows: [ transaction ], before_copy: alter_cache) do |context|
        publish_identities(context)
        before = retained_state(context)

        assert_raises(History::Conflict) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "unlinked empty discovery accounts retain a bound while nonempty cached history refuses" do
    [ [], nil, [ transaction ] ].each do |rows|
      with_enable_banking_migration_source(rows: rows, linked: false) do |context|
        before = retained_state(context)

        if rows.present?
          assert_raises(History::Conflict) { verify_history(context) }
        else
          assert_nil verify_history(context)
        end

        assert_equal before, retained_state(context)
        assert_empty context.account.entries
      end
    end
  end

  test "the exact copied consent and authorization membership remain unchanged during verification" do
    with_enable_banking_migration_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      authorization = context.connection.provider_authorizations.sole
      membership = context.external.provider_authorization_accounts.sole
      assert_equal authorization.id, membership.provider_authorization_id
      assert authorization.active?
      assert_equal context.item.session_id, authorization.credentials.fetch("session_id")
      assert_nil authorization.external_id
      assert_equal context.source.uid, context.external.external_id
      descriptor = Provider::AccountData::MigrationValue.decode(context.external.metadata.fetch("source_details"))
      assert_equal context.source.account_id, descriptor.fetch("identity").fetch("account_id")
      refute_equal context.source.uid, context.source.account_id
      before = retained_state(context)

      assert_nil verify_history(context)
      assert_equal before, retained_state(context)
    end
  end

  test "consent state credentials or membership drift refuse the original route" do
    %i[session expired authorization_status membership missing_membership].each do |change|
      with_enable_banking_migration_source do |context|
        authorization = context.connection.provider_authorizations.sole
        membership = context.external.provider_authorization_accounts.sole
        case change
        when :session then authorization.update!(credentials: authorization.credentials.merge("session_id" => SecureRandom.uuid))
        when :expired then authorization.update!(expires_at: 1.minute.ago)
        when :authorization_status then authorization.update!(status: "requires_update")
        when :membership then membership.update!(status: "revoked")
        when :missing_membership then membership.delete
        end
        before = retained_state(context)

        assert_raises(History::Conflict, change.to_s) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "legacy consent API UID and financial currency changes cannot be adopted after copying" do
    %i[session authorization_attempt api_uid currency].each do |change|
      with_enable_banking_migration_source(rows: [ transaction ]) do |context|
        publish_identities(context)
        case change
        when :session then context.item.update!(session_id: SecureRandom.uuid)
        when :authorization_attempt then context.item.update!(authorization_id: SecureRandom.uuid)
        when :api_uid then context.source.update!(account_id: SecureRandom.uuid)
        when :currency then context.account.update!(currency: "USD")
        end
        before = retained_state(context)

        error_class = change == :authorization_attempt ? Fence::OwnershipChanged : History::Conflict
        assert_raises(error_class, change.to_s) { verify_history(context) }
        assert_equal before, retained_state(context)
      end
    end
  end

  test "bounded inventory and financial proof budgets refuse without financial writes" do
    with_enable_banking_migration_source(rows: [ transaction ]) do |context|
      publish_identities(context)
      before = retained_state(context)
      %i[MAX_ACCOUNTS MAX_RECORDS MAX_BYTES MAX_IDENTITY_BYTES].each do |name|
        with_history_limit(name, 0) { assert_raises(History::Conflict) { verify_history(context) } }
      end
      assert_equal before, retained_state(context)
    end
  end

  test "final transaction exclusive admission and exact family are mandatory" do
    with_enable_banking_migration_source do |context|
      assert_raises(ArgumentError) { verifier(context).verify! }
      ApplicationRecord.transaction { assert_raises(Fence::InvalidSource) { verifier(context).verify! } }
      Fence.with_exclusive(context.item) do
        ApplicationRecord.transaction do
          assert_raises(History::Conflict) do
            History.new(item: context.item, connection: context.connection, family: families(:empty)).verify!
          end
        end
      end
    end
  end

  test "actual preparation and gated cutover preserve signed originals and consent while replaying the initial Sync" do
    [ nil, Date.new(2026, 8, 1) ].each do |start|
      with_enable_banking_migration_source(rows: [ transaction ], item_attributes: { sync_start_date: start }) do |context|
        original_policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions").attributes
        prepare_enable_banking_migration(context)
        policies = Account::SourcePolicy.active.where(account: context.account).order(:resource).map(&:attributes)
        assert_equal %w[balances transactions], policies.map { |policy| policy.fetch("resource") }
        assert_equal original_policy, policies.find { |policy| policy.fetch("resource") == "transactions" }
        before = retained_state(context).slice(:financial, :observations, :postings, :batches, :authorizations, :memberships, :checkpoints)
        Provider::AccountData::EnableBanking.stubs(:native_ready?).returns(true)
        result = nil

        queries = capture_sql_queries do
          assert_enqueued_with(job: SyncJob) { result = cutover_enable_banking_migration(context) }
        end

        refute result.replayed
        sync = context.connection.syncs.sole
        assert_equal result.sync_id, sync.id
        assert sync.pending?
        assert_nil sync.window_start_date
        assert_nil sync.window_end_date
        assert context.connection.reload.good?
        assert context.control.reload.active?
        assert_equal 1, context.connection.writer_epoch
        assert_equal 1, context.control.writer_epoch
        assert_equal start&.iso8601, context.external.reload.metadata.fetch("enable_banking_initial_history_start")
        receipt = context.control.audit_results.fetch("native_cutover")
        assert_equal({ context.external.id => start&.iso8601 }, receipt.fetch("account_starts"))
        assert_equal context.control.preparation_state.fetch("run_id"), receipt.fetch("preparation_run_id")
        assert_equal context.control.high_water_mark.fetch("copy_run_id"), receipt.fetch("copy_run_id")
        assert_equal before, retained_state(context).slice(*before.keys)
        assert_no_financial_sql(queries)
        original_sync = sync.attributes
        after = retained_state(context)
        replay = nil

        assert_enqueued_with(job: SyncJob) { replay = cutover_enable_banking_migration(context) }

        assert replay.replayed
        assert_equal result.sync_id, replay.sync_id
        assert_equal original_sync, sync.reload.attributes
        assert_equal 1, context.connection.syncs.count
        assert_equal after, retained_state(context)
      end
    end
  end

  test "production readiness refuses cutover without constructing a provider or activating ownership" do
    with_enable_banking_migration_source do |context|
      prepare_enable_banking_migration(context)
      before = retained_state(context)
      refute Provider::AccountData::EnableBanking.native_ready?

      assert_no_enqueued_jobs do
        assert_raises(Provider::AccountData::UnsupportedCapability) { cutover_enable_banking_migration(context) }
      end

      assert context.control.reload.quiescing?
      assert context.connection.reload.disabled?
      assert_empty context.connection.syncs
      assert_equal before, retained_state(context)
    end
  end

  test "native initial windows distinguish explicit full history configured dates and the unchanged default" do
    observed = Time.utc(2026, 9, 16, 12)
    [ [ nil, nil ], [ "2020-01-02", Date.new(2020, 1, 2) ], [ :absent, (observed - 90.days).to_date ] ].each do |hint, expected|
      client = mock("Enable Banking initial history transport")
      metadata = { "authorization_id" => "original-consent" }
      metadata["enable_banking_initial_history_start"] = hint unless hint == :absent
      adapter = window_adapter(client, observed: observed)
      account = Ingestion::Record.account(external_id: "stable-account", name: "Checking", currency: "EUR",
        metadata: metadata, sensitive_details: { api_account_id: "api-account" })
      start = adapter.initial_history_start(account: account.attributes, observed_at: observed)
      client.expects(:get_ingestion_transactions_page).with do |**arguments|
        assert_equal "api-account", arguments.fetch(:account_id)
        assert_equal expected, arguments.fetch(:date_from)
        assert_equal observed.to_date, arguments.fetch(:date_to)
        assert_equal "BOOK", arguments.fetch(:transaction_status)
        assert_equal observed.to_date, arguments.fetch(:reference_date)
        assert_equal 0, ApplicationRecord.connection.open_transactions
        true
      end.returns(items: [], next_cursor: nil, date_from: expected, date_to: observed.to_date)

      page = adapter.fetch_transactions(account: account, window: { start: start, end: observed })

      assert page.complete?
      assert_empty page.records
      assert_equal [ "enable_banking_initial_history_start" ], Provider::AccountData::EnableBanking.initial_history_metadata_keys
    end
  end

  test "malformed first-history metadata is refused before transport" do
    observed = Time.utc(2026, 9, 16, 12)
    client = mock("Uncalled Enable Banking history transport")
    client.expects(:get_ingestion_transactions_page).never
    adapter = window_adapter(client, observed: observed)

    [ "", "2026-02-30", "2026-9-01", "2026-09-01T00:00:00Z", 123, {} ].each do |hint|
      assert_raises(Provider::AccountData::InvalidResponse) do
        adapter.initial_history_start(account: { metadata: { "enable_banking_initial_history_start" => hint } }, observed_at: observed)
      end
    end
  end

  test "a narrowed first BOOK page keeps history incomplete through continuation and the terminal pending page" do
    observed = Time.utc(2026, 9, 16, 12)
    narrowed = Date.new(2026, 9, 1)
    client = mock("Enable Banking narrowed history")
    adapter = window_adapter(client, observed: observed, include_pending: true)
    account = window_account
    requests = sequence("narrowed continuation then pending")
    client.expects(:get_ingestion_transactions_page).with(has_entries(transaction_status: "BOOK", continuation_key: nil, date_from: nil))
      .in_sequence(requests).returns(items: [], next_cursor: "book-tail", date_from: narrowed, date_to: observed.to_date, narrowed_window: true)
    client.expects(:get_ingestion_transactions_page).with(has_entries(transaction_status: "BOOK", continuation_key: "book-tail", date_from: narrowed))
      .in_sequence(requests).returns(items: [], next_cursor: nil, date_from: narrowed, date_to: observed.to_date)
    client.expects(:get_ingestion_transactions_page).with(has_entries(transaction_status: "PDNG", continuation_key: nil, date_from: narrowed))
      .in_sequence(requests).returns(items: [], next_cursor: nil, date_from: narrowed, date_to: observed.to_date)

    first = adapter.fetch_transactions(account: account, window: { start: nil, end: observed })
    second = adapter.fetch_transactions(account: account, cursor: first.next_cursor)
    last = adapter.fetch_transactions(account: account, cursor: second.next_cursor)

    refute first.complete?
    refute second.complete?
    assert last.complete?
    [ first, second, last ].each do |page|
      assert_equal false, page.coverage.fetch("history_complete")
      assert_equal false, page.coverage.fetch("pending_absence_authoritative")
    end
    assert_equal "transaction_window_narrowed", first.warnings.sole.fetch("code")
    assert_empty last.warnings
  end

  test "pending unsupported cannot restore history completeness after BOOK narrowed the request" do
    observed = Time.utc(2026, 9, 16, 12)
    client = mock("Enable Banking narrowed pending unsupported")
    adapter = window_adapter(client, observed: observed, include_pending: true)
    requests = sequence("narrowed then unsupported")
    client.expects(:get_ingestion_transactions_page).with(has_entries(transaction_status: "BOOK"))
      .in_sequence(requests).returns(items: [], next_cursor: nil, date_from: Date.new(2026, 9, 1), date_to: observed.to_date, narrowed_window: true)
    client.expects(:get_ingestion_transactions_page).with(has_entries(transaction_status: "PDNG"))
      .in_sequence(requests).raises(Provider::EnableBanking::EnableBankingError.new("Pending unsupported", :bad_request))

    first = adapter.fetch_transactions(account: window_account, window: { start: nil, end: observed })
    last = adapter.fetch_transactions(account: window_account, cursor: first.next_cursor)

    assert last.complete?
    assert_equal false, last.coverage.fetch("history_complete")
    assert_equal false, last.coverage.fetch("pending_absence_authoritative")
    assert_equal "pending_unsupported", last.warnings.sole.fetch("code")
  end

  private
    def transaction(changes = {})
      enable_banking_migration_transaction(changes)
    end

    def window_adapter(client, observed:, include_pending: false)
      Provider::AccountData::EnableBanking.new(client: client, timezone: "UTC", external_accounts: [],
        known_merchant_names: [], observed_at: observed, include_pending: include_pending,
        authorizations: [ { id: "original-consent", status: "active", expires_at: "2027-01-01T00:00:00Z",
          credentials: { session_id: "private-original-consent" }, metadata: {} } ])
    end

    def window_account
      Ingestion::Record.account(external_id: "stable-account", name: "Checking", currency: "EUR",
        metadata: { authorization_id: "original-consent", enable_banking_initial_history_start: nil },
        sensitive_details: { api_account_id: "api-account" })
    end

    def publish_identities(context)
      publisher = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family)
      result = nil
      10.times do
        result = publisher.run
        break if result.verified?
      end
      assert result.verified?
    end

    def verifier(context)
      History.new(item: context.item, connection: context.connection, family: context.family)
    end

    def verify_result(context)
      Fence.with_exclusive(context.item) do
        ApplicationRecord.transaction(requires_new: true) { verifier(context).verify! }
      end
    end

    def verify_history(context)
      verify_result(context).account_starts.fetch(context.external.id)
    end

    def retained_state(context)
      observations = SourceRecord.where(external_account: context.external)
      { financial: identity_financial_snapshot(context), control: context.control.reload.attributes,
        connection: context.connection.reload.attributes, external: context.external.reload.attributes,
        source: context.source.reload.attributes, item: context.item.reload.attributes,
        observations: observations.order(:id).map(&:attributes),
        postings: EntrySource.where(source_record_id: observations.select(:id)).order(:id).map(&:attributes),
        batches: context.connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text")),
        authorizations: context.connection.provider_authorizations.order(:id).map(&:attributes),
        memberships: context.external.provider_authorization_accounts.order(:id).map(&:attributes),
        checkpoints: context.connection.provider_sync_checkpoints.order(:id).map(&:attributes) }
    end

    def with_history_limit(name, value)
      previous = History.const_get(name)
      History.send(:remove_const, name)
      History.const_set(name, value)
      yield
    ensure
      History.send(:remove_const, name)
      History.const_set(name, previous)
    end
end
