require "test_helper"
require_relative "../../../../support/akahu_migration_test_helper"

class Provider::AccountData::Akahu::PendingIdentityTest < ActiveSupport::TestCase
  include AkahuMigrationTestHelper
  self.use_transactional_tests = false

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
    clear_enqueued_jobs
  end
  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "copied idless pending refresh settlement and late replay retain the original signed financial identity" do
    with_akahu_migration_source(rows: [ pending_raw ]) do |context|
      entry = context.account.entries.sole
      base = entry.external_id
      observation = SourceRecord.find_by!(external_account: context.external, external_id: base)
      posting = observation.entry_source
      proof = original_proof(posting)
      assert_equal [ base, 0 ], [ observation.input_external_id, observation.input_occurrence ]
      assert_equal [ base, base, 0 ], Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: posting, source_record: observation)
        .fetch(:identity).values_at("external_id", "input_external_id", "input_occurrence")

      assert_no_difference "Entry.count" do
        perform_native(context, pending: [ pending_raw ])
        perform_native(context, posted: [ posted_raw ], pending: [ pending_raw ])
        perform_native(context, posted: [ posted_raw ], pending: [ pending_raw ])
      end

      assert_equal entry.id, context.account.entries.sole.id
      assert_equal "akahu_settled", entry.reload.external_id
      refute entry.transaction.pending?
      assert_includes entry.transaction.extra.fetch("auto_claimed_pending_ids"), base
      assert observation.reload.withdrawn?
      refute observation.pending?
      assert_equal posting.id, observation.entry_source.id
      assert_equal entry.id, observation.entry_source.entry_identity
      assert_equal proof, original_proof(posting.reload)
      assert_equal [ base, "akahu_settled" ].sort, SourceRecord.where(external_account: context.external).order(:external_id).pluck(:external_id)
      assert Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: posting, source_record: observation)
    end
  end

  test "user changes and financial protections survive idless settlement and retired replay" do
    %i[user_modified import_locked reconciled].each do |protection|
      with_akahu_migration_source(rows: [ pending_raw ]) do |context|
        entry = context.account.entries.sole
        attributes = { name: "User description", notes: "User note" }
        attributes[protection == :reconciled ? :reconciled_at : protection] = protection == :reconciled ? Time.current : true
        entry.update!(attributes)
        before = entry.reload.attributes.except("external_id", "source", "updated_at", "lock_version")
        proof = original_proof(entry.entry_sources.sole)

        assert_no_difference "Entry.count" do
          apply(context, normalized(context, posted_raw))
          apply(context, normalized(context, pending_raw))
        end

        assert_equal "akahu_settled", entry.reload.external_id
        assert_equal before, entry.attributes.except("external_id", "source", "updated_at", "lock_version")
        original = entry.entry_sources.find_by!(bootstrap_identity_role: "current")
        assert_equal proof, original_proof(original)
      end
    end
  end

  test "a signed original retired idless alias is suppressed after legacy settlement" do
    with_akahu_migration_source(rows: [ pending_raw, posted_raw ]) do |context|
      entry = context.account.entries.sole
      assert_equal "akahu_settled", entry.external_id
      alias_record = SourceRecord.find_by!(external_account: context.external, external_id: normalized(context, pending_raw)[:external_id])
      assert_equal "retired_alias", alias_record.entry_source.bootstrap_identity_role
      before = [ entry.attributes, entry.transaction.attributes, alias_record.attributes ]

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        apply(context, normalized(context, pending_raw))
      end

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes, alias_record.reload.attributes ]
    end
  end

  test "current account currency cannot reinterpret a migrated idless pending hash" do
    [ false, true ].each do |explicit_currency|
      with_akahu_migration_source(rows: [ pending_raw ]) do |context|
        entry = context.account.entries.sole
        observation = SourceRecord.find_by!(external_account: context.external, external_id: entry.external_id)
        before = [ entry.reload.attributes, entry.transaction.reload.attributes, observation.attributes ]
        proof = original_proof(observation.entry_source)
        raw = explicit_currency ? pending_raw : pending_raw.except("currency")

        assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
          perform_native(context, currency: "USD", pending: [ raw ], expected_status: explicit_currency ? "completed" : "failed")
        end

        assert_equal "USD", context.account.reload.currency
        assert_equal "USD", context.external.reload.currency
        assert_equal "NZD", entry.reload.currency
        assert_equal BigDecimal("12.34"), entry.amount
        assert_equal proof, original_proof(observation.entry_source)
        unless explicit_currency
          assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes, observation.reload.attributes ]
          assert_nil context.connection.provider_sync_checkpoints.find_by(stream: "transactions")
        end
      end
    end
  end

  test "native-only active idless postings also refuse reuse in a different monetary unit" do
    with_akahu_migration_source(rows: []) do |context|
      apply(context, normalized(context, pending_raw))
      entry = context.account.entries.sole
      observation = SourceRecord.find_by!(external_account: context.external, external_id: entry.external_id)
      assert_nil observation.entry_source.bootstrap_batch_id
      before = [ entry.reload.attributes, entry.transaction.reload.attributes, observation.attributes ]

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        perform_native(context, currency: "USD", pending: [ pending_raw.except("currency") ], expected_status: "failed")
      end

      assert_equal "USD", context.account.reload.currency
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes, observation.reload.attributes ]
      assert_nil context.connection.provider_sync_checkpoints.find_by(stream: "transactions")
    end
  end

  test "native-only idless settlement also retains its withdrawn alias across late replay" do
    with_akahu_migration_source(rows: []) do |context|
      pending = normalized(context, pending_raw)
      apply(context, pending)
      entry = context.account.entries.sole
      original_mapping = entry.entry_sources.sole
      assert_nil original_mapping.bootstrap_batch_id
      apply(context, normalized(context, posted_raw))
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] { apply(context, pending) }

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert_equal entry.id, context.account.entries.sole.id
      assert SourceRecord.find_by!(external_account: context.external, external_id: pending[:external_id]).withdrawn?
    end
  end

  test "an explicit idless tombstone cannot be reinterpreted as a reusable pending alias" do
    [ false, true ].each do |protected|
      with_akahu_migration_source(rows: [ pending_raw ]) do |context|
        entry = context.account.entries.sole
        entry.update!(import_locked: true) if protected
        pending = normalized(context, pending_raw)
        apply(context, removed_ids: [ pending[:external_id] ])
        observation = SourceRecord.find_by!(external_account: context.external, external_id: pending[:external_id])
        assert observation.withdrawn?
        assert_equal protected, Entry.exists?(entry.id)
        before = [ observation.attributes, observation.entry_sources.order(:id).map(&:attributes) ]

        assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
          assert_raises(Ingestion::MappedEntryResolver::Conflict) { apply(context, pending) }
        end

        assert_equal before, [ observation.reload.attributes, observation.entry_sources.order(:id).map(&:attributes) ]
      end
    end
  end

  test "a migrated pending base never assigns a second response occurrence to a guessed suffix" do
    with_akahu_migration_source(rows: [ pending_raw ]) do |context|
      pending = normalized(context, pending_raw)
      repeated = Ingestion::Record.transaction(**pending.attributes.merge(metadata: pending[:metadata].merge(identity_occurrence: 1)))
      entry = context.account.entries.sole
      observation = SourceRecord.find_by!(external_account: context.external, external_id: pending[:external_id])
      before = [ entry.reload.attributes, entry.transaction.reload.attributes, observation.attributes ]

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Ingestion::MappedEntryResolver::Conflict) { apply(context, pending, repeated) }
      end

      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes, observation.reload.attributes ]
    end
  end

  test "identical copied occurrences and persisted suffix families remain explicit blockers" do
    with_akahu_migration_source(rows: [ pending_raw, pending_raw ], cutover: false) do |context|
      assert_equal 1, context.account.entries.count # The legacy importer collapsed this duplicate.
      prepare_akahu_migration(context)
      before = identity_financial_snapshot(context)

      assert_raises(Provider::AccountData::Akahu::CutoverHistory::Conflict) { cutover_akahu_migration(context) }

      assert_equal before, identity_financial_snapshot(context)
      assert context.connection.disabled?
    end
    with_akahu_migration_source(rows: [ pending_raw.except("_pending"), pending_raw ], cutover: false) do |context|
      assert_equal 2, context.account.entries.count
      before = identity_financial_snapshot(context)
      plan = Provider::AccountData::IdentityBootstrapPlan.new(mapping: context.mapping, family: context.family).page

      assert_equal [ "unresolved_input_occurrence", "unresolved_input_occurrence" ], plan.document.fetch("blockers").map { |row| row.fetch("code") }
      assert_equal before, identity_financial_snapshot(context)
      assert context.connection.disabled?
    end
  end

  test "a corrupted permanent bootstrap proof cannot become an allocated suffix" do
    with_akahu_migration_source(rows: [ pending_raw ]) do |context|
      pending = normalized(context, pending_raw)
      posting = context.account.entries.sole.entry_sources.sole
      batch = posting.bootstrap_batch
      original = IngestionBatch.where(id: batch.id).pick(Arel.sql("payload::text"))
      IngestionBatch.where(id: batch.id).update_all(payload: { "invalid" => true })
      before = identity_financial_snapshot(context)
      begin
        assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
          assert_raises(Ingestion::MappedEntryResolver::Conflict) { apply(context, pending) }
        end
        assert_equal before, identity_financial_snapshot(context)
      ensure
        IngestionBatch.where(id: batch.id).update_all([ "payload = ?", original ])
      end
    end
  end

  private
    def pending_raw
      akahu_migration_transaction("date" => (Date.current - 2).iso8601).except("_id").merge("_pending" => true)
    end

    def posted_raw
      akahu_migration_transaction("_id" => "settled", "date" => (Date.current - 2).iso8601)
    end

    def normalized(context, raw)
      Provider::AccountData::Akahu.new(client: nil, timezone: context.family.timezone)
        .normalize_legacy_transaction(raw, account: { external_id: context.source.account_id, currency: context.account.currency })
    end

    def original_proof(posting)
      [ posting.attributes.slice("id", "bootstrap_batch_id", "bootstrap_external_account_id", "bootstrap_identity_role", "entry_identity"),
        IngestionBatch.where(id: posting.bootstrap_batch_id).pick(Arel.sql("payload::text")) ]
    end

    def apply(context, *records, removed_ids: [])
      page = Provider::AccountData::Page.new(records: records, removed_ids: removed_ids, complete: true, mode: "delta",
        coverage: { "pending_absence_authoritative" => false, "removal_policy" => "exact_external_id" })
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "transactions")
      batch = create_provider_batch(context.connection, external_account: context.external, stream: "transactions",
        payload: Ingestion::Codec.dump(page), source_policy_version: policy.id)
      IngestionBatch.transaction(requires_new: true) do
        Ingestion::LedgerWriter.new(external_account: context.external, batch: batch).apply(page)
        batch.update!(status: "applied", applied_at: Time.current)
      end
      batch.sync.update!(status: "completed", completed_at: Time.current)
      batch
    end

    def perform_native(context, posted: [], pending: [], currency: "NZD", expected_status: "completed")
      client = mock("native Akahu pending source")
      client.expects(:get_accounts_page).with(cursor: nil).returns(items: [ {
        _id: context.source.account_id, name: context.source.name, type: "CHECKING",
        balance: { currency: currency, current: "100.00" }
      } ], next_cursor: nil)
      client.expects(:get_account_transactions_page).with(account_id: context.source.account_id,
        start_date: anything, end_date: anything, cursor: nil).returns(items: posted, next_cursor: nil)
      client.expects(:get_pending_transactions_page).with(cursor: nil).returns(items: pending, next_cursor: nil)
      sync = context.connection.syncs.create!
      Provider::Akahu.stub(:new, client) { SyncJob.perform_now(sync) }
      assert_equal expected_status, sync.reload.status
      clear_enqueued_jobs
    end
end
