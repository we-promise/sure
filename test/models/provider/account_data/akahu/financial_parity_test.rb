require "test_helper"
require_relative "../../../../support/akahu_migration_test_helper"

class Provider::AccountData::Akahu::FinancialParityTest < ActiveSupport::TestCase
  include AkahuMigrationTestHelper
  self.use_transactional_tests = false

  # Only the provider transport is replaced. Registry construction, captured
  # request admission, pagination, checkpoints and LedgerWriter remain real.
  class Client
    attr_reader :requests

    def initialize(account:, posted:, pending:, before_read:)
      @account, @posted, @pending, @before_read = account, posted, pending, before_read
      @requests = []
    end

    def get_accounts_page(cursor:)
      read(:accounts, cursor: cursor)
      { items: [ @account ], next_cursor: nil }
    end

    def get_account_transactions_page(account_id:, start_date:, end_date:, cursor:)
      read(:posted, account_id: account_id, start: start_date, end: end_date, cursor: cursor)
      { items: @posted, next_cursor: nil }
    end

    def get_pending_transactions_page(cursor:)
      read(:pending, cursor: cursor)
      { items: @pending, next_cursor: nil }
    end

    private
      def read(phase, **options)
        @before_read.call
        @requests << options.merge(phase: phase)
      end
  end

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    DebugLogEntry.stubs(:capture)
    # This suite stops at native financial publication; child account balance
    # materialization is a separate job and has its own execution coverage.
    Account.any_instance.stubs(:sync_later)
    Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "first native replay preserves signed legacy UUIDs merchant notes and Akahu metadata" do
    with_merchant_row do |raw|
      with_akahu_migration_source(rows: [ raw ], cutover: false) do |context|
        entry = context.account.entries.sole
        original = financial_record(entry)
        merchant = entry.transaction.merchant
        prepare_akahu_migration(context)
        proof = original_proof(context)
        archives = original_archives(context)

        assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count", "ProviderMerchant.count" ] do
          perform_native(context, posted: [ raw ])
        end

        assert_equal original, financial_record(entry)
        assert_equal proof, original_proof(context)
        assert_equal archives, original_archives(context)
        assert_equal merchant.id, entry.transaction.reload.merchant_id
        assert_equal raw.fetch("merchant").fetch("_id"), merchant.provider_merchant_id
        assert_equal raw.fetch("merchant").fetch("name"), merchant.name
        assert_equal raw.fetch("merchant").fetch("website"), merchant.website_url
        assert_equal "akahu", merchant.source
        assert_equal expected_notes(raw), entry.reload.notes
        assert_equal expected_extra(raw), entry.transaction.extra.fetch("akahu")
        assert_equal "provider", observation_for(context).ingestion_batch.origin_kind
      end
    end
  end

  test "an unprotected native correction updates the original entry while keeping its signed baseline" do
    raw = akahu_migration_transaction
    with_akahu_migration_source(rows: [ raw ], cutover: false) do |context|
      entry = context.account.entries.sole
      ids = [ entry.id, entry.entryable_id ]
      prepare_akahu_migration(context)
      proof = original_proof(context)
      corrected = raw.deep_merge("amount" => "-17.25", "date" => "2020-01-03",
        "description" => "Corrected description", "meta" => { "reference" => "Corrected reference" })

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        perform_native(context, posted: [ corrected ])
      end

      assert_equal ids, [ entry.reload.id, entry.entryable_id ]
      assert_equal BigDecimal("17.25"), entry.amount
      assert_equal Date.new(2020, 1, 3), entry.date
      assert_equal "Corrected description", entry.name
      assert_equal expected_notes(corrected), entry.notes
      assert_equal "Corrected reference", entry.transaction.extra.dig("akahu", "reference")
      assert_equal proof, original_proof(context)
    end
  end

  test "new native transactions publish merchant identity website notes and categorized source metadata" do
    with_merchant_row do |raw|
      with_akahu_migration_source(rows: [], cutover: false) do |context|
        prepare_akahu_migration(context)

        assert_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count", "ProviderMerchant.count" ], 1 do
          perform_native(context, posted: [ raw ])
        end

        entry = context.account.entries.sole
        merchant = entry.transaction.merchant
        assert_equal raw.fetch("merchant").fetch("_id"), merchant.provider_merchant_id
        assert_equal raw.fetch("merchant").fetch("name"), merchant.name
        assert_equal raw.fetch("merchant").fetch("website"), merchant.website_url
        assert_equal "akahu", merchant.source
        assert_equal merchant.name, entry.name
        assert_equal expected_notes(raw), entry.notes
        assert_equal expected_extra(raw), entry.transaction.extra.fetch("akahu")
        assert_equal entry.id, observation_for(context).entry_source.entry_id
      end
    end
  end

  {
    "user changes" => { user_modified: true },
    "import locks" => { import_locked: true },
    "excluded entries" => { excluded: true },
    "reconciliation" => { reconciled_at: Time.utc(2026, 9, 15) }
  }.each do |label, protection|
    test "native replay preserves #{label} after signed bootstrap" do
      raw = akahu_migration_transaction
      with_akahu_migration_source(rows: [ raw ], cutover: false) do |context|
        prepare_akahu_migration(context)
        entry = context.account.entries.sole
        entry.update!({ name: "User description", notes: "User note", amount: 35 }.merge(protection))
        before = [ entry.reload.attributes, entry.transaction.reload.attributes ]
        proof = original_proof(context)

        assert_no_difference [ "Entry.count", "Transaction.count", "EntrySource.count" ] do
          perform_native(context, posted: [ raw.merge("amount" => "-99", "description" => "Provider correction") ])
        end

        assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
        assert_equal proof, original_proof(context)
        assert_equal entry.id, observation_for(context).entry_source.entry_identity
        assert_equal "provider", observation_for(context).ingestion_batch.origin_kind
      end
    end
  end

  %w[CreditCard Loan].each do |type|
    test "#{type} native API balance uses the legacy absolute value for debt credit and zero" do
      %w[-123.45 12.34 0].each do |raw_balance|
        with_akahu_migration_source(rows: [], cutover: false, process_account: true,
          account_attributes: { accountable: type.constantize.new },
          source_attributes: { current_balance: raw_balance }) do |context|
          legacy = balance_record(context.account)
          assert_equal BigDecimal(raw_balance).abs, legacy.fetch("balance")
          assert_equal legacy.fetch("balance"), legacy.fetch("cash_balance")
          original_id = context.account.accountable_id
          prepare_akahu_migration(context)
          context.account.update!(balance: 999, cash_balance: 888)

          assert_no_difference [ "Account.count", "Entry.count", "Transaction.count" ] do
            perform_native(context, posted: [], balance: raw_balance)
          end

          assert_equal legacy, balance_record(context.account)
          assert_equal original_id, context.account.reload.accountable_id
          assert_equal type, context.account.accountable_type
        end
      end
    end
  end

  test "Investment native publication preserves total balance and zero cash" do
    with_akahu_migration_source(rows: [], cutover: false, process_account: true,
      account_attributes: { accountable: Investment.new }, source_attributes: { current_balance: "321.09" }) do |context|
      legacy = balance_record(context.account)
      assert_equal BigDecimal("321.09"), legacy.fetch("balance")
      assert_equal BigDecimal("0"), legacy.fetch("cash_balance")
      prepare_akahu_migration(context)
      context.account.update!(balance: 999, cash_balance: 999)

      perform_native(context, posted: [], balance: "321.09")

      assert_equal legacy, balance_record(context.account)
    end
  end

  test "Depository keeps a negative balance instead of applying the liability transform" do
    with_akahu_migration_source(rows: [], cutover: false, process_account: true,
      source_attributes: { current_balance: "-23.45" }) do |context|
      legacy = balance_record(context.account)
      prepare_akahu_migration(context)
      context.account.update!(balance: 999, cash_balance: 999)

      perform_native(context, posted: [], balance: "-23.45")

      assert_equal BigDecimal("-23.45"), context.account.reload.balance
      assert_equal legacy, balance_record(context.account)
    end
  end

  test "a current API currency change publishes the new monetary unit and transaction fallback currency" do
    with_akahu_migration_source(rows: [], cutover: false) do |context|
      prepare_akahu_migration(context)
      raw = akahu_migration_transaction.except("currency")

      assert_difference "context.account.entries.count", 1 do
        perform_native(context, posted: [ raw ], balance: "45.67", currency: "USD")
      end

      assert_equal "USD", context.account.reload.currency
      assert_equal BigDecimal("45.67"), context.account.balance
      assert_equal BigDecimal("45.67"), context.account.cash_balance
      assert_equal "USD", context.external.reload.currency
      assert_equal "USD", context.external.metadata.fetch("reported_currency")
      assert_equal "USD", context.account.entries.sole.currency
      assert_equal BigDecimal("12.34"), context.account.entries.sole.amount
    end
  end

  test "explicit transaction currency stays distinct from the account currency" do
    raw = akahu_migration_transaction("currency" => "USD")
    with_akahu_migration_source(rows: [ raw ], cutover: false) do |context|
      entry = context.account.entries.sole
      prepare_akahu_migration(context)

      perform_native(context, posted: [ raw ])

      assert_equal "NZD", context.account.reload.currency
      assert_equal "USD", entry.reload.currency
      assert_equal entry.id, context.account.entries.sole.id
      assert_equal BigDecimal("12.34"), entry.amount
    end
  end

  test "a balance currency transition retains old explicit-currency postings and their original archive" do
    old = akahu_migration_transaction
    with_akahu_migration_source(rows: [ old ], cutover: false) do |context|
      entry = context.account.entries.sole
      financial = financial_record(entry)
      prepare_akahu_migration(context)
      archives = original_archives(context)
      bootstrap = observation_for(context).entry_source
      original_mapping = bootstrap.attributes
      recent = akahu_migration_transaction("_id" => "new-usd-transaction", "amount" => "-4.56",
        "date" => "2026-09-15", "description" => "New unit purchase").except("currency")

      assert_difference [ "Entry.count", "Transaction.count" ], 1 do
        perform_native(context, posted: [ old, recent ], balance: "45.67", currency: "USD")
      end

      assert_equal({ "balance" => BigDecimal("45.67"), "cash_balance" => BigDecimal("45.67"), "currency" => "USD" }, balance_record(context.account))
      assert_equal financial, financial_record(entry)
      assert_equal original_mapping, bootstrap.reload.attributes
      assert_equal archives, original_archives(context)
      new_entry = context.account.entries.find_by!(source: "akahu", external_id: "akahu_new-usd-transaction")
      assert_equal [ BigDecimal("4.56"), "USD" ], [ new_entry.amount, new_entry.currency ]
      assert_equal [ BigDecimal("12.34"), "NZD" ], [ entry.reload.amount, entry.currency ]
    end
  end

  test "a stable legacy pending ID posts on the same financial UUID through both native phases" do
    raw = akahu_migration_transaction("_pending" => true)
    with_akahu_migration_source(rows: [ raw ], cutover: false) do |context|
      entry = context.account.entries.sole
      assert entry.transaction.pending?
      ids = [ entry.id, entry.entryable_id ]
      prepare_akahu_migration(context)
      proof = original_proof(context)

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        perform_native(context, posted: [ raw.except("_pending") ])
      end

      assert_equal ids, [ entry.reload.id, entry.entryable_id ]
      refute entry.transaction.reload.pending?
      refute observation_for(context).pending?
      assert_equal proof, original_proof(context)
    end
  end

  test "first native acquisition requests full history despite a recent legacy success and retains both phases" do
    with_akahu_migration_source(cutover: false) do |context|
      assert_equal Time.current, context.item.syncs.completed.sole.completed_at
      prepare_akahu_migration(context)
      client, sync = perform_native(context, posted: context.source.raw_transactions_payload)

      assert_nil sync.window_start_date
      assert_nil client.requests.find { |request| request[:phase] == :posted }.fetch(:start)
      assert_equal sync.created_at, Time.iso8601(client.requests.find { |request| request[:phase] == :posted }.fetch(:end))
      assert_nil context.external.reload.metadata.fetch("akahu_initial_history_start")
      assert_equal({ context.external.id => nil }, context.control.reload.audit_results.fetch("native_cutover").fetch("account_starts"))
      captures = native_transaction_batches(context, sync)
      assert_equal %w[posted pending], captures.map { |batch| Ingestion::Codec.load(batch.payload).evidence.fetch("phase") }
      assert captures.all?(&:applied?)
      refute Ingestion::Codec.load(captures.first.payload).complete?
      assert Ingestion::Codec.load(captures.last.payload).complete?
      checkpoint = context.connection.provider_sync_checkpoints.find_by!(external_account: context.external, stream: "transactions")
      assert_equal captures.last.id, checkpoint.ingestion_batch_id
      assert_equal sync.created_at, checkpoint.covered_through
    end
  end

  { "item" => nil, "source" => Date.new(2021, 3, 4) }.each do |label, source_start|
    test "first native request preserves the configured #{label} history floor" do
      item_start = Date.new(2020, 2, 3)
      with_akahu_migration_source(rows: [], cutover: false,
        item_attributes: { sync_start_date: item_start }, source_attributes: { sync_start_date: source_start }) do |context|
        prepare_akahu_migration(context)
        client, sync = perform_native(context, posted: [])
        expected = source_start || item_start

        assert_nil sync.window_start_date
        assert_equal expected, Time.iso8601(client.requests.find { |request| request[:phase] == :posted }.fetch(:start)).to_date
        assert_equal expected.iso8601, context.external.reload.metadata.fetch("akahu_initial_history_start")
        assert_equal({ context.external.id => expected.iso8601 }, context.control.reload.audit_results.fetch("native_cutover").fetch("account_starts"))
      end
    end
  end

  private
    def perform_native(context, posted:, pending: [], balance: "100", currency: "NZD")
      sync = cutover_akahu_migration(context)
      client = Client.new(account: account_payload(context, balance: balance, currency: currency), posted: posted, pending: pending,
        before_read: -> { assert_equal 0, ApplicationRecord.connection.open_transactions })
      Provider::Akahu.expects(:new).with(app_token: context.item.app_token, user_token: context.item.user_token).returns(client)

      Provider::AccountData::Syncer.new(context.connection.reload).perform_sync(sync)

      assert_equal [ :accounts, :posted, :pending ], client.requests.map { |request| request.fetch(:phase) }
      assert client.requests.all? { |request| request.fetch(:cursor).nil? }
      assert_equal context.source.account_id, client.requests.find { |request| request[:phase] == :posted }.fetch(:account_id)
      assert_equal %w[balances transactions], Account::SourcePolicy.active.where(account: context.account).order(:resource).pluck(:resource)
      %w[accounts balances transactions].each do |stream|
        checkpoint = context.connection.provider_sync_checkpoints.find_by!(stream: stream)
        assert checkpoint.ingestion_batch.applied?, "#{stream} must publish its original captured page"
      end
      [ client, sync ]
    end

    def account_payload(context, balance:, currency:)
      { "_id" => context.source.account_id, "name" => "Checking", "type" => context.source.account_type,
        "status" => "ACTIVE", "balance" => { "current" => balance, "available" => balance, "currency" => currency },
        "connection" => { "_id" => "bank", "name" => "Fixture bank" } }
    end

    def with_merchant_row
      identity = "akahu-parity-#{SecureRandom.uuid}"
      merchant = { "_id" => identity, "name" => "Merchant #{identity}", "website" => "https://merchant.example.test" }
      yield akahu_migration_transaction("merchant" => merchant,
        "category" => { "_id" => "groceries", "name" => "Groceries", "groups" => { "personal_finance" => { "name" => "Food" } } },
        "meta" => { "reference" => "REF", "particulars" => "DETAIL", "code" => "CODE", "other_account" => "retained-peer" })
    ensure
      ProviderMerchant.where(source: "akahu", provider_merchant_id: identity).destroy_all if identity
    end

    def expected_notes(raw)
      parts = []
      parts << raw.fetch("description") if raw.dig("merchant", "name").present?
      %w[reference particulars code other_account].each do |field|
        value = raw.dig("meta", field)
        parts << "#{I18n.t("akahu_entry.notes.#{field}")}: #{value}" if value.present?
      end
      parts.presence&.join(" | ")
    end

    def expected_extra(raw)
      { "pending" => false, "type" => raw.fetch("type"), "category" => raw.dig("category", "name"),
        "category_id" => raw.dig("category", "_id"), "category_group" => raw.dig("category", "groups", "personal_finance", "name"),
        "reference" => raw.dig("meta", "reference"), "particulars" => raw.dig("meta", "particulars"),
        "code" => raw.dig("meta", "code"), "other_account" => raw.dig("meta", "other_account") }.compact
    end

    def financial_record(entry)
      { entry: entry.reload.attributes.except("created_at", "updated_at"),
        transaction: entry.transaction.reload.attributes.except("created_at", "updated_at") }
    end

    def balance_record(account)
      account.reload.attributes.slice("balance", "cash_balance", "currency")
    end

    def observation_for(context)
      SourceRecord.where(external_account: context.external).sole
    end

    def original_proof(context)
      mapping = observation_for(context).entry_source.reload
      batch = IngestionBatch.find(mapping.bootstrap_batch_id)
      [ mapping.attributes, batch.attributes, batch.read_attribute_before_type_cast("payload") ]
    end

    def original_archives(context)
      context.connection.ingestion_batches.where(origin_kind: "migration").order(:id).map do |batch|
        [ batch.id, batch.attributes, batch.read_attribute_before_type_cast("payload") ]
      end
    end

    def native_transaction_batches(context, sync)
      context.connection.ingestion_batches.where(sync_id: sync.id, stream: "transactions").order(:sequence).to_a
    end
end
