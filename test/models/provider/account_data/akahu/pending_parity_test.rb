require "test_helper"
require_relative "../../../../support/akahu_migration_test_helper"

class Provider::AccountData::Akahu::PendingParityTest < ActiveSupport::TestCase
  include AkahuMigrationTestHelper
  self.use_transactional_tests = false

  class Client
    attr_reader :requests

    def initialize(account:, posted:, pending:, before_read:)
      @account, @posted, @pending, @before_read = account, posted, pending, before_read
      @requests = []
    end

    def get_accounts_page(cursor:)
      read(:accounts, cursor, { nil => { items: [ @account ], next_cursor: nil } })
    end

    def get_account_transactions_page(account_id:, start_date:, end_date:, cursor:)
      read(:posted, cursor, @posted)
    end

    def get_pending_transactions_page(cursor:)
      read(:pending, cursor, @pending)
    end

    private
      def read(phase, cursor, responses)
        @before_read.call
        @requests << [ phase, cursor ]
        response = responses.fetch(cursor)
        raise response if response.is_a?(Exception)
        response.respond_to?(:call) ? response.call : response
      end
  end

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
    Account.any_instance.stubs(:sync_later)
  end

  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "complete empty pending inventory withdraws signed absent holds outside the history floor and keeps posted history" do
    pending = pending_row("missing")
    posted = posted_row
    with_prepared(rows: [ pending, posted ], source_attributes: { sync_start_date: Date.new(2026, 1, 1) }) do |context, sync|
      missing = entry_for(context, pending)
      booked = entry_for(context, posted)
      before = economic_record(booked)
      observation = observation_for(context, pending)
      original_mapping = permanent_mapping(observation)
      archives = archives_for(context)

      assert_difference [ "Entry.count", "Transaction.count" ], -1 do
        run_native(context, sync)
      end

      refute Entry.exists?(missing.id)
      assert_equal before, economic_record(booked)
      assert observation.reload.withdrawn?
      refute observation.pending?
      mapping = observation.entry_sources.sole
      assert_nil mapping.entry_id
      refute mapping.active?
      assert_equal original_mapping, permanent_mapping(observation)
      assert_equal archives, archives_for(context)
      assert_complete_checkpoint(context, sync)
    end
  end

  test "only a terminal full pending page prunes identities absent from the union of all pages" do
    first, last, absent = %w[first last absent].map { |id| pending_row(id) }
    with_prepared(rows: [ first, last, absent ]) do |context, sync|
      original_ids = context.account.entries.pluck(:external_id, :id).to_h
      terminal = lambda do
        assert_equal original_ids.values.sort, context.account.entries.pluck(:id).sort
        assert SourceRecord.where(external_account: context.external).all?(&:pending?)
        assert_nil transaction_checkpoint(context)
        page([ last ])
      end

      client = run_native(context, sync, pending: { nil => page([ first ], cursor: "tail"), "tail" => terminal })

      assert_equal [ [ :accounts, nil ], [ :posted, nil ], [ :pending, nil ], [ :pending, "tail" ] ], client.requests
      [ first, last ].each do |raw|
        entry = entry_for(context, raw)
        assert_equal original_ids.fetch(identity(raw)), entry.id
        assert entry.transaction.pending?
        refute observation_for(context, raw).withdrawn?
      end
      refute Entry.exists?(original_ids.fetch(identity(absent)))
      assert observation_for(context, absent).withdrawn?
      assert_complete_checkpoint(context, sync)
    end
  end

  test "a failed pending tail retains absent holds and same Sync retries only the uncaptured tail" do
    present, absent = %w[present absent].map { |id| pending_row(id) }
    with_prepared(rows: [ present, absent ]) do |context, sync|
      missing = entry_for(context, absent)
      original = economic_record(missing)
      assert_raises(Provider::AccountData::Error) do
        run_native(context, sync, pending: { nil => page([ present ], cursor: "tail"), "tail" => IOError.new("Pending page unavailable") })
      end
      assert_equal original, economic_record(missing)
      refute observation_for(context, absent).withdrawn?
      assert_nil transaction_checkpoint(context)
      prefix = transaction_batches(context, sync).map { |batch| [ batch.id, batch.attributes, batch.read_attribute_before_type_cast("payload") ] }
      assert_equal 2, prefix.size
      assert transaction_batches(context, sync).all?(&:applied?)

      client = nil
      assert_difference "Entry.count", -1 do
        client = run_native(context, sync, posted: {}, pending: { "tail" => page([]) })
      end

      assert_equal [ [ :pending, "tail" ] ], client.requests
      assert_equal prefix, transaction_batches(context, sync).first(2).map { |batch| [ batch.id, batch.attributes, batch.read_attribute_before_type_cast("payload") ] }
      assert entry_for(context, present).transaction.pending?
      refute Entry.exists?(missing.id)
      assert observation_for(context, absent).withdrawn?
      assert_complete_checkpoint(context, sync)
    end
  end

  test "posted acquisition failure cannot lend pending absence authority" do
    pending = pending_row("retained")
    with_prepared(rows: [ pending ]) do |context, sync|
      entry = entry_for(context, pending)
      before = [ economic_record(entry), observation_for(context, pending).attributes ]
      client = build_client(context, posted: { nil => IOError.new("Posted page unavailable") }, pending: {})

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Provider::AccountData::Error) { execute(context, sync, client) }
      end

      assert_equal [ [ :accounts, nil ], [ :posted, nil ] ], client.requests
      assert_equal before, [ economic_record(entry), observation_for(context, pending).attributes ]
      assert_empty transaction_batches(context, sync)
      assert_nil transaction_checkpoint(context)
    end
  end

  test "malformed complete pending responses never become empty authoritative inventories" do
    [ { next_cursor: nil }, { items: nil, next_cursor: nil }, { items: [], next_cursor: 12 } ].each do |response|
      pending = pending_row("retained")
      with_prepared(rows: [ pending ]) do |context, sync|
        entry = entry_for(context, pending)
        before = [ economic_record(entry), observation_for(context, pending).attributes ]

        assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
          assert_raises(Provider::AccountData::Error) { run_native(context, sync, pending: { nil => response }) }
        end

        assert_equal before, [ economic_record(entry), observation_for(context, pending).attributes ]
        assert_nil transaction_checkpoint(context)
        assert_equal [ "posted" ], transaction_batches(context, sync).map { |batch| Ingestion::Codec.load(batch.payload).evidence.fetch("phase") }
      end
    end
  end

  test "native idless occurrences survive paging and only unprotected stale occurrences are removed later" do
    with_prepared(rows: []) do |context, sync|
      raw = pending_row("unused").except("_id")
      run_native(context, sync, pending: { nil => page([ raw ], cursor: "tail"), "tail" => page([ raw ]) })
      entries = context.account.entries.order(:external_id).to_a
      assert_equal 2, entries.size
      assert_equal [ 0, 1 ], SourceRecord.where(external_account: context.external).order(:input_occurrence).pluck(:input_occurrence)
      assert entries.all? { |entry| entry.external_id.start_with?("akahu_pending_") && entry.transaction.pending? }
      kept, missing = entries
      kept.update!(import_locked: true, notes: "User retained occurrence")
      original = economic_record(kept)
      sync.update!(status: "completed", completed_at: Time.current)
      followup = context.connection.syncs.create!

      assert_difference "Entry.count", -1 do
        run_native(context, followup)
      end

      assert_equal original, economic_record(kept)
      refute kept.transaction.reload.pending?
      refute Entry.exists?(missing.id)
      assert SourceRecord.where(external_account: context.external).all?(&:withdrawn?)
      retired = SourceRecord.find_by!(external_account: context.external, external_id: missing.external_id).entry_sources.sole
      assert_equal missing.id, retired.entry_identity
      assert_nil retired.entry_id
      assert_complete_checkpoint(context, followup)
    end
  end

  test "complete absence keeps user protected and reconciled legacy financial rows" do
    { user_modified: true, import_locked: true, excluded: true, reconciled_at: Time.utc(2026, 9, 15),
      locked_attributes: { "amount" => true } }.each do |field, value|
      raw = pending_row("protected")
      with_prepared(rows: [ raw ]) do |context, sync|
        entry = entry_for(context, raw)
        entry.update!(field => value)
        original = economic_record(entry)
        proof = permanent_mapping(observation_for(context, raw))

        assert_no_difference [ "Entry.count", "Transaction.count" ] { run_native(context, sync) }

        assert_equal original, economic_record(entry)
        refute entry.transaction.reload.pending?
        assert observation_for(context, raw).withdrawn?
        assert_equal proof, permanent_mapping(observation_for(context, raw))
      end
    end
  end

  test "a transaction-only extra lock preserves its original pending metadata on withdrawal" do
    raw = pending_row("locked-extra")
    with_prepared(rows: [ raw ]) do |context, sync|
      entry = entry_for(context, raw)
      entry.transaction.update!(locked_attributes: { "extra" => true })
      original = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      assert_no_difference [ "Entry.count", "Transaction.count" ] { run_native(context, sync) }

      assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert entry.transaction.pending?
      assert observation_for(context, raw).withdrawn?
    end
  end

  test "pending absence preserves a transfer leg and a fee without destroying or changing its other financial rows" do
    %i[leg fee].each do |role|
      raw = pending_row("transfer-#{role}")
      with_prepared(rows: [ raw ]) do |context, sync|
        entry = entry_for(context, raw)
        other = context.family.accounts.create!(owner: context.actor, name: "Transfer peer", currency: "NZD", balance: 100, accountable: Depository.new)
        inflow = other.entries.create!(name: "Transfer inflow", date: entry.date, currency: "NZD", amount: -12.34, entryable: Transaction.new(kind: "funds_movement"))
        outflow = role == :leg ? entry : context.account.entries.create!(name: "Transfer outflow", date: entry.date,
          currency: "NZD", amount: 12.34, entryable: Transaction.new(kind: "funds_movement"))
        transfer = Transfer.create!(inflow_transaction: inflow.transaction, outflow_transaction: outflow.transaction)
        if role == :fee
          entry.transaction.update!(transfer_id: transfer.id)
        else
          entry.transaction.update!(kind: "funds_movement")
        end
        original = [ economic_record(entry), economic_record(inflow), economic_record(outflow), transfer.attributes ]

        assert_no_difference [ "Entry.count", "Transaction.count", "Transfer.count" ] { run_native(context, sync) }

        assert_equal original, [ economic_record(entry), economic_record(inflow), economic_record(outflow), transfer.reload.attributes ]
        refute entry.transaction.reload.pending?
        assert observation_for(context, raw).withdrawn?
      end
    end
  end

  test "pending absence retains a split parent and its user-authored children" do
    raw = pending_row("split")
    with_prepared(rows: [ raw ]) do |context, sync|
      entry = entry_for(context, raw)
      children = entry.split!([ { name: "User split one", amount: "5" }, { name: "User split two", amount: "7.34" } ])
      original = [ economic_record(entry), children.map { |child| economic_record(child) } ]

      assert_no_difference [ "Entry.count", "Transaction.count" ] { run_native(context, sync) }

      assert_equal original, [ economic_record(entry), children.map { |child| economic_record(child) } ]
      assert_equal children.map(&:id).sort, entry.child_entries.pluck(:id).sort
      refute entry.transaction.reload.pending?
      assert observation_for(context, raw).withdrawn?
    end
  end

  test "a new account currency does not reinterpret retained explicit-currency pending or posted financial values" do
    pending, posted = pending_row("old-unit"), posted_row
    with_prepared(rows: [ pending, posted ]) do |context, sync|
      held, booked = entry_for(context, pending), entry_for(context, posted)
      held.update!(user_modified: true, notes: "Keep original NZD hold")
      original = [ economic_record(held), economic_record(booked) ]
      proof = permanent_mapping(observation_for(context, pending))

      assert_no_difference [ "Entry.count", "Transaction.count" ] do
        run_native(context, sync, currency: "USD")
      end

      assert_equal "USD", context.account.reload.currency
      assert_equal "USD", context.external.reload.currency
      assert_equal original, [ economic_record(held), economic_record(booked) ]
      assert_equal %w[NZD NZD], [ held.currency, booked.currency ]
      refute held.transaction.reload.pending?
      assert observation_for(context, pending).withdrawn?
      refute observation_for(context, posted).withdrawn?
      assert_equal proof, permanent_mapping(observation_for(context, pending))
      assert transaction_batches(context, sync).all? { |batch| batch.source_binding.fetch("account_currency") == "USD" }
    end
  end

  private
    def pending_row(id)
      akahu_migration_transaction("_id" => id, "_pending" => true, "description" => "Pending #{id}")
    end

    def posted_row
      akahu_migration_transaction("_id" => "booked", "amount" => "-25", "description" => "Historical posted")
    end

    def page(rows, cursor: nil)
      { items: rows, next_cursor: cursor }
    end

    def with_prepared(rows:, **options)
      with_akahu_migration_source(rows: rows, cutover: false, **options) do |context|
        prepare_akahu_migration(context)
        yield context, cutover_akahu_migration(context)
      end
    end

    def build_client(context, posted: { nil => { items: [], next_cursor: nil } }, pending: { nil => { items: [], next_cursor: nil } }, currency: "NZD")
      Client.new(account: { "_id" => context.source.account_id, "name" => "Checking", "type" => "CHECKING",
        "balance" => { "current" => "100", "currency" => currency } }, posted: posted, pending: pending,
        before_read: -> { assert_equal 0, ApplicationRecord.connection.open_transactions })
    end

    def run_native(context, sync, **options)
      client = build_client(context, **options)
      execute(context, sync, client)
      client
    end

    def execute(context, sync, client)
      Provider::Akahu.stubs(:new).returns(client)
      Provider::AccountData::Syncer.new(context.connection.reload).perform_sync(sync)
    end

    def identity(raw)
      "akahu_#{raw.fetch("_id")}"
    end

    def entry_for(context, raw)
      context.account.entries.find_by!(source: "akahu", external_id: identity(raw))
    end

    def observation_for(context, raw)
      SourceRecord.find_by!(external_account: context.external, external_id: identity(raw))
    end

    def economic_record(entry)
      entry.reload
      transaction = entry.transaction.reload
      extra = transaction.extra.deep_dup
      extra.fetch("akahu", {}).delete("pending")
      [ entry.attributes.except("updated_at"), transaction.attributes.except("updated_at", "extra"), extra ]
    end

    def permanent_mapping(observation)
      observation.entry_sources.sole.attributes.except("entry_id", "active", "updated_at")
    end

    def archives_for(context)
      context.connection.ingestion_batches.where(origin_kind: "migration").order(:id).pluck(:id, Arel.sql("payload::text"))
    end

    def transaction_batches(context, sync)
      context.connection.ingestion_batches.where(sync_id: sync.id, stream: "transactions").order(:sequence).to_a
    end

    def transaction_checkpoint(context)
      context.connection.provider_sync_checkpoints.find_by(external_account: context.external, stream: "transactions")
    end

    def assert_complete_checkpoint(context, sync)
      checkpoint = transaction_checkpoint(context)
      assert checkpoint
      assert_equal sync.id, checkpoint.ingestion_batch.sync_id
      assert checkpoint.ingestion_batch.applied?
      page = Ingestion::Codec.load(checkpoint.ingestion_batch.payload)
      assert page.complete?
      assert_equal "pending", page.evidence.fetch("phase")
      assert_equal "all", page.coverage.fetch("pending_scope")
      assert_equal sync.created_at, checkpoint.covered_through
    end
end
