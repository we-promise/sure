require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"
require_relative "../../../support/provider_account_locking_test_helper"

class Provider::AccountData::TransactionSyncTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ProviderAccountLockingTestHelper

  class Reader
    attr_reader :requests

    def initialize(&reader)
      @reader, @requests = reader, []
    end

    def fetch_transaction_group(**request)
      @requests << request
      @reader.call(**request)
    end
  end

  test "capture seal and promotion share account UUID lock order regardless of provider page order" do
    with_provider_encryption do
      connection, first, second = linked_accounts
      ordered = [ first, second ].sort_by { |external| external.current_account.id }
      reader = Reader.new do |**request|
        group(request, ordered.reverse.to_h { |external| [ external.external_id, [ record("lock-order-#{external.external_id}") ] ] })
      end
      synchronizer = runner(connection, reader)
      phase_locks = {}
      # Observe the three multi-account boundaries independently of the bounded
      # one-account writes. SQL inspection verifies the PostgreSQL lock contract.
      %i[create_generation seal promote].each do |method|
        observer = self
        synchronizer.define_singleton_method(method) do |*args|
          result = nil
          phase_locks[method] = observer.capture_provider_locks { result = super(*args) }
          result
        end
      end
      generation = synchronizer.perform
      assert generation.applied?
      assert_equal 2, generation.children.where(status: "applied").count
      %i[create_generation seal promote].each do |phase|
        assert_ordered_account_locks phase_locks.fetch(phase), ordered.map(&:current_account)
      end
      assert_equal generation.id, connection.provider_sync_checkpoints.find_by!(stream: "transactions").provider_sync_generation_id
    end
  end

  test "a connection change log is captured before publication and its cursor waits for every account" do
    with_provider_encryption do
      connection, first, second = linked_accounts
      sync = connection.syncs.create!
      ids = %w[group-first group-second]
      reader = Reader.new do |**request|
        assert_empty SourceRecord.where(external_account: [ first, second ])
        assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
        captured = connection.provider_sync_generations.find(request.fetch(:generation_id))
        assert_equal [ first.current_account.id, second.current_account.id ].sort, captured.account_ids
        assert_equal captured.account_ids, Provider::AccountData::GenerationAccountIndex.verify!(generation: captured)
        if request[:cursor].nil?
          group(request, { first.external_id => [ record(ids.first) ] }, cursor: "next-page", complete: false)
        else
          group(request, { second.external_id => [ record(ids.last) ] }, cursor: "committed-terminal")
        end
      end
      generation = runner(connection, reader, sync: sync).perform
      assert generation.applied?
      assert_equal 2, generation.pages.count
      assert_equal 2, generation.children.where(status: "applied").count
      assert_equal 2, SourceRecord.where(external_account: [ first, second ]).count
      generation.children.each do |batch|
        external = batch.external_account
        assert_equal generation.context_snapshot.fetch("accounts").fetch(external.external_id), batch.source_binding
      end
      cursor = connection.provider_sync_checkpoints.find_by!(stream: "transactions", scope_key: "connection")
      assert_equal "committed-terminal", cursor.cursor
      assert_equal generation.id, cursor.provider_sync_generation_id
      assert_nil cursor.ingestion_batch_id
      assert_provider_column_encrypted(generation, :terminal_cursor, "committed-terminal")
      assert_provider_column_encrypted(generation.pages.first, :payload, "group-first")
      assert_provider_column_encrypted(generation, :context_snapshot, first.external_id)
      no_reads = Reader.new { flunk "Applied generation must not fetch again" }
      assert_no_difference [ "Entry.count", "SourceRecord.count", "IngestionBatch.count", "ProviderSyncGeneration.count" ] do
        assert_equal generation.id, runner(connection, no_reads, sync: sync).perform.id
      end
    end
  end

  test "a failed continuation leaves no financial prefix and the next run starts from the committed cursor" do
    with_provider_encryption do
      connection, first, = linked_accounts
      connection.provider_sync_checkpoints.create!(stream: "transactions", scope_key: "connection", cursor: "last-committed")
      reader = Reader.new do |**request|
        raise Provider::AccountData::InvalidResponse, "Unavailable continuation" unless request[:cursor] == "last-committed"
        group(request, { first.external_id => [ record("abandoned-prefix") ] }, cursor: "uncommitted-page", complete: false)
      end
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::InvalidResponse) { runner(connection, reader).perform }
      end
      abandoned = connection.provider_sync_generations.sole
      assert abandoned.abandoned?
      assert_equal 1, abandoned.pages.count
      assert_equal "last-committed", connection.provider_sync_checkpoints.find_by!(stream: "transactions").cursor
      replacement = Reader.new do |**request|
        assert_equal "last-committed", request[:cursor]
        group(request, { first.external_id => [ record("replacement-transaction") ] }, cursor: "new-committed")
      end
      assert_difference "SourceRecord.count", 1 do
        runner(connection, replacement).perform
      end
      assert_nil first.current_account.entries.find_by(external_id: "abandoned-prefix")
    end
  end

  test "provider mutation restarts the whole generation with a bounded retry budget" do
    with_provider_encryption do
      connection, first, = linked_accounts
      reader = Reader.new do |**request|
        if request[:cursor].nil?
          group(request, { first.external_id => [ record("never-posted") ] }, cursor: "continuation", complete: false)
        else
          raise Provider::AccountData::PaginationRestartRequired.new(generation_id: request[:generation_id], start_cursor: request[:start_cursor])
        end
      end
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::PaginationRestartRequired) { runner(connection, reader).perform }
      end
      assert_equal 6, reader.requests.size
      assert_equal 3, reader.requests.map { |request| request[:generation_id] }.uniq.size
      assert_equal 3, connection.provider_sync_generations.where(status: "abandoned").count
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
    end
  end

  test "a crash after terminal capture resumes the captured generation without another provider request" do
    with_provider_encryption do
      connection, first, = linked_accounts
      reader = Reader.new { |**request| group(request, { first.external_id => [ record("captured-before-crash") ] }) }
      interrupted = runner(connection, reader)
      interrupted.define_singleton_method(:seal) { |_generation| raise IOError, "Process interrupted before sealing" }
      assert_raises(IOError) { interrupted.perform }
      captured = connection.provider_sync_generations.sole
      assert captured.fetching?
      assert_empty captured.children
      assert_equal captured.account_ids, Provider::AccountData::GenerationAccountIndex.verify!(generation: captured)
      assert_includes Provider::AccountData::GenerationAccountIndex.for_account(first.current_account).pluck(:id), captured.id
      assert_empty SourceRecord.where(external_account: first)
      no_reads = Reader.new { flunk "The terminal response is already captured" }
      result = runner(connection, no_reads).perform
      assert_equal captured.id, result.id
      assert result.applied?
      assert first.current_account.entries.find_by!(external_id: "captured-before-crash")
    end
  end

  test "a crash after one child commit resumes outstanding children without duplicating financial entries" do
    with_provider_encryption do
      connection, first, second = linked_accounts
      reader = Reader.new do |**request|
        group(request, { first.external_id => [ record("first-committed") ], second.external_id => [ record("second-after-retry") ] })
      end
      failing_writer = Class.new(Ingestion::LedgerWriter) do
        def apply(page, **options)
          raise IOError, "Temporary account failure" if page.records.any? { |record| record[:external_id] == "second-after-retry" }
          super
        end
      end
      assert_raises(IOError) { runner(connection, reader, ledger_writer: failing_writer).perform }
      sealed = connection.provider_sync_generations.sole
      assert sealed.sealed?
      assert_equal 1, sealed.children.where(status: "applied").count
      first_entry_id = first.current_account.entries.find_by!(external_id: "first-committed").id
      assert_nil second.current_account.entries.find_by(external_id: "second-after-retry")
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
      no_reads = Reader.new { flunk "A sealed generation cannot fetch a replacement" }
      assert_difference "Entry.count", 1 do
        runner(connection, no_reads).perform
      end
      assert_equal first_entry_id, first.current_account.entries.find_by!(external_id: "first-committed").id
      assert sealed.reload.applied?
    end
  end

  test "child failures roll back financial writes before saving a scoped diagnostic without private data" do
    with_provider_encryption do
      connection, first, = linked_accounts
      reader = Reader.new do |**request|
        group(request, { first.external_id => [ record("private-failed-record") ] }, cursor: "private-uncommitted-cursor")
      end
      failing_writer = Class.new(Ingestion::LedgerWriter) do
        def apply(page, **options)
          super
          raise IOError, "Private upstream response access_token=secret-value"
        end
      end
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_difference "DebugLogEntry.count", 1 do
          assert_raises(IOError) { runner(connection, reader, ledger_writer: failing_writer).perform }
        end
      end
      generation = connection.provider_sync_generations.sole
      batch = generation.children.sole
      assert_not batch.applied?
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
      diagnostic = DebugLogEntry.find_by!(source: "Provider::AccountData::TransactionSync", family: connection.family,
        account_provider: first.account_provider)
      assert_equal "up", diagnostic.provider_key
      assert_equal({ "provider_connection_id" => connection.id, "sync_id" => generation.sync_id,
        "generation_id" => generation.id, "batch_id" => batch.id, "external_account_id" => first.id,
        "error_class" => "IOError" }, diagnostic.metadata)
      %w[private-failed-record private-uncommitted-cursor access_token secret-value].each do |private_value|
        assert_not_includes diagnostic.attributes.to_json, private_value
      end
    end
  end

  test "source selection changed during fetching cannot be substituted when the generation seals" do
    with_provider_encryption do
      connection, first, = linked_accounts
      alternate = create_provider_connection(provider_key: "plaid")
      alternate_external = create_external_account(alternate)
      alternate_link = AccountProvider.create!(account: first.current_account, external_account: alternate_external)
      reader = Reader.new do |**request|
        Account::SourcePolicy.select!(account: first.current_account, account_provider: alternate_link, resource: "transactions")
        group(request, { first.external_id => [ record("wrong-authority") ] })
      end
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { runner(connection, reader).perform }
      end
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
      assert connection.provider_sync_generations.sole.fetching?
      assert_empty connection.provider_sync_generations.sole.children
    end
  end

  test "unlinked account history remains captured and requires backfill before it can join subsequent generations" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection, external_id: "unlinked-history-account")
      reader = Reader.new { |**request| group(request, { external.external_id => [ record("retained-history") ] }) }
      generation = nil
      assert_no_difference "Entry.count" do
        assert_difference "SourceRecord.count", 1 do
          generation = runner(connection, reader).perform
        end
      end
      assert generation.applied?
      assert external.reload.transaction_backfill_required?
      assert_nil generation.children.sole.source_policy_version
      assert_equal "retained-history", Ingestion::Codec.load(generation.children.sole.payload).records.sole[:external_id]
      observation = SourceRecord.find_by!(external_account: external, external_id: "retained-history")
      assert_nil observation.account_id
      assert_empty observation.entry_sources
      link = AccountProvider.create!(account: accounts(:depository), external_account: external)
      Account::SourcePolicy.select!(account: link.account, account_provider: link, resource: "transactions")
      no_reads = Reader.new { flunk "A newly linked account requires explicit replay first" }
      assert_raises(Provider::AccountData::IncompletePage) { runner(connection, no_reads).perform }
      assert_equal 1, connection.provider_sync_generations.count
    end
  end

  test "later unassigned removals resolve retained unlinked identities without creating financial entries" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection, external_id: "unlinked-pending-account")
      first = Reader.new { |**request| group(request, { external.external_id => [ record("unlinked-pending-id") ] }, cursor: "initial-retained") }
      runner(connection, first).perform
      removed = Reader.new { |**request| group(request, {}, unassigned: [ "unlinked-pending-id" ], cursor: "removed-retained") }
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        runner(connection, removed).perform
      end
      observation = SourceRecord.find_by!(external_account: external, external_id: "unlinked-pending-id")
      assert_nil observation.account_id
      assert observation.withdrawn?
      assert_empty observation.entry_sources
      assert_equal "removed-retained", connection.provider_sync_checkpoints.find_by!(stream: "transactions", scope_key: "connection").cursor
    end
  end

  test "a secondary connection captures source evidence without a second financial posting" do
    with_provider_encryption do
      connection, first, = linked_accounts
      alternate = create_provider_connection(provider_key: "plaid")
      alternate_external = create_external_account(alternate)
      alternate_link = AccountProvider.create!(account: first.current_account, external_account: alternate_external)
      Account::SourcePolicy.select!(account: first.current_account, account_provider: alternate_link, resource: "transactions")
      reader = Reader.new { |**request| group(request, { first.external_id => [ record("secondary-observation") ] }) }
      assert_no_difference "Entry.count" do
        runner(connection, reader).perform
      end
      observation = SourceRecord.find_by!(external_account: first, external_id: "secondary-observation")
      assert_nil observation.entry_source
      assert observation.ingestion_batch.applied?
    end
  end

  test "unknown unassigned removals stop promotion and cannot use another connection's identity" do
    with_provider_encryption do
      first_connection, first, = linked_accounts
      initial = Reader.new { |**request| group(request, { first.external_id => [ record("foreign-removal-id") ] }) }
      runner(first_connection, initial).perform
      other_connection = create_provider_connection
      reader = Reader.new { |**request| group(request, {}, unassigned: [ "foreign-removal-id" ]) }
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Ingestion::TransactionGroupAssembler::UnresolvedRemoval) { runner(other_connection, reader).perform }
      end
      assert_nil other_connection.provider_sync_checkpoints.find_by(stream: "transactions")
      assert first.current_account.entries.find_by!(external_id: "foreign-removal-id")
    end
  end

  test "known unassigned removals route by same-connection evidence and preserve the original entry UUID" do
    with_provider_encryption do
      connection, first, = linked_accounts
      initial = Reader.new { |**request| group(request, { first.external_id => [ record("known-removal-id") ] }) }
      runner(connection, initial).perform
      entry_id = first.current_account.entries.find_by!(external_id: "known-removal-id").id
      removed = Reader.new { |**request| group(request, {}, unassigned: [ "known-removal-id" ], cursor: "removed-terminal") }
      runner(connection, removed).perform
      observation = SourceRecord.find_by!(external_account: first, external_id: "known-removal-id")
      assert observation.withdrawn?
      assert_nil first.current_account.entries.find_by(id: entry_id)
      assert_equal entry_id, observation.entry_sources.sole.entry_identity
      assert_equal "removed-terminal", connection.provider_sync_checkpoints.find_by!(stream: "transactions").cursor
    end
  end

  test "large account deltas commit bounded children under a single connection checkpoint" do
    with_provider_encryption do
      connection, first, = linked_accounts
      records = 1_001.times.map { |index| record("bounded-#{index}") }
      reader = Reader.new { |**request| group(request, { first.external_id => records }) }
      # Use the secondary-source path to exercise real evidence persistence without
      # running a thousand unrelated accounting/materialization callbacks here.
      alternate = create_provider_connection(provider_key: "plaid")
      alternate_link = AccountProvider.create!(account: first.current_account, external_account: create_external_account(alternate))
      Account::SourcePolicy.select!(account: first.current_account, account_provider: alternate_link, resource: "transactions")
      generation = runner(connection, reader).perform
      assert_equal [ 1_000, 1 ], generation.children.map { |batch| Ingestion::Codec.load(batch.payload).records.size }
      assert_equal 1_001, SourceRecord.where(external_account: first).count
      assert_equal 1, connection.provider_sync_checkpoints.where(stream: "transactions").count
      assert_nil connection.provider_sync_checkpoints.find_by(external_account: first, stream: "transactions")
    end
  end

  test "direct token replacement during capture cannot publish under the replacement grant" do
    with_provider_encryption do
      connection, first, = linked_accounts
      reader = Reader.new do |**request|
        connection.update!(credentials: { "access_token" => "replacement-private-token" })
        group(request, { first.external_id => [ record("wrong-token-grant") ] })
      end
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { runner(connection, reader).perform }
      end
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
      assert_empty connection.provider_sync_generations.sole.pages
    end
  end

  test "a changed provider environment cannot resume a sealed generation" do
    with_provider_encryption do
      connection, first, = linked_accounts
      reader = Reader.new { |**request| group(request, { first.external_id => [ record("old-environment") ] }) }
      interrupted = runner(connection, reader)
      interrupted.define_singleton_method(:apply_children) { |_generation| raise IOError, "Stopped after sealing" }
      assert_raises(IOError) { interrupted.perform }
      assert connection.provider_sync_generations.sole.sealed?
      connection.update!(environment: "replacement")
      no_reads = Reader.new { flunk "Changed grants cannot resume provider reads" }
      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { runner(connection, no_reads).perform }
      end
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
    end
  end

  test "credential replacement after child commits leaves the old cursor unchanged" do
    with_provider_encryption do
      connection, first, = linked_accounts
      reader = Reader.new { |**request| group(request, { first.external_id => [ record("committed-before-revocation") ] }) }
      interrupted = runner(connection, reader)
      interrupted.define_singleton_method(:promote) do |generation|
        connection.update!(credential_revision: connection.credential_revision + 1)
        super(generation)
      end
      assert_raises(Provider::AccountData::StaleWriter) { interrupted.perform }
      generation = connection.provider_sync_generations.sole
      assert generation.sealed?
      assert generation.children.sole.applied?
      assert first.current_account.entries.find_by!(external_id: "committed-before-revocation")
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "transactions")
    end
  end

  test "a cached adapter grant cannot be replaced by the generation's newer database snapshot" do
    with_provider_encryption do
      connection, first, = linked_accounts
      authorization = connection.provider_authorizations.create!(credentials: { "session_id" => "first-grant" })
      ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: first)
      captured = Provider::AccountData::RequestGrant.new(connection).capture!
      authorization.update!(credentials: { "session_id" => "different-grant" })
      reader = Reader.new { flunk "An obsolete adapter must not perform HTTP" }
      execution = Provider::AccountData::TransactionSync.new(connection: connection, sync: connection.syncs.create!, adapter: reader,
        writer_epoch: connection.writer_epoch, fence: ->(&block) { connection.with_lock(&block) }, request_grant: captured)
      assert_no_difference [ "ProviderSyncGeneration.count", "IngestionBatch.count", "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { execution.perform }
      end
    end
  end

  private
    def runner(connection, reader, sync: connection.syncs.create!, ledger_writer: Ingestion::LedgerWriter)
      Provider::AccountData::TransactionSync.new(connection: connection, sync: sync, adapter: reader,
        writer_epoch: connection.writer_epoch, fence: ->(&block) { connection.with_lock(&block) }, ledger_writer: ledger_writer)
    end

    def linked_accounts
      connection = create_provider_connection
      external = [ [ "account-a", accounts(:depository) ], [ "account-b", accounts(:investment) ] ].map do |id, account|
        value = create_external_account(connection, external_id: id)
        link = AccountProvider.create!(account: account, external_account: value)
        Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
        value
      end
      [ connection, *external ]
    end

    def record(id)
      Ingestion::Record.transaction(external_id: id, name: "Purchase #{id}", amount: BigDecimal("12.34"),
        currency: "USD", date: Date.current, pending: false)
    end

    def group(request, records_by_account, cursor: "terminal-cursor", complete: true, unassigned: [])
      pages = records_by_account.transform_values { |records| Provider::AccountData::Page.new(records: records, complete: false, mode: "delta") }
      Provider::AccountData::TransactionGroup.new(generation_id: request.fetch(:generation_id), start_cursor: request.fetch(:start_cursor),
        request_cursor: request.fetch(:cursor), next_cursor: cursor, complete: complete, account_pages: pages,
        unassigned_removed_ids: unassigned, evidence: {})
    end
end
