require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::MercuryMigrationCutoverTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Cutover = Provider::AccountData::MigrationCutover
  Preparation = Provider::AccountData::MigrationPreparation
  Selection = Provider::AccountData::MigrationSourceSelection

  class Client
    attr_reader :requests

    def initialize(remote_id, rows, &before_read)
      @remote_id, @rows, @before_read, @requests = remote_id, rows, before_read, []
    end

    def get_accounts_page(cursor:)
      @before_read.call
      { items: [ { id: @remote_id, name: "Checking", currentBalance: "100.00", status: "active", type: "checking" } ], next_cursor: nil }
    end

    def get_account_transactions_page(remote_id, cursor:, start_date:, end_date:)
      @before_read.call
      @requests << { remote_id: remote_id, start: start_date, end: end_date }
      { items: @rows, next_cursor: nil }
    end
  end

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    # Exercise the complete command without changing production readiness.
    Provider::AccountData::Mercury.stubs(:native_ready?).returns(true)
  end

  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "Mercury cutover retains original financial and proof identities through the first native replay" do
    with_source do |context, rows|
      assert_empty Account::SourcePolicy.where(account: context.account)
      original_entry = context.account.entries.sole
      preparation = finish_preparation(context)
      original_entry.update!(name: "My retained name", notes: "My retained note", user_modified: true, import_locked: true)
      financial = identity_financial_snapshot(context)
      link = context.link.reload.attributes
      evidence = retained_evidence(context)
      policies = Account::SourcePolicy.where(account: context.account).order(:resource).map(&:attributes)
      assert_equal %w[balances transactions], policies.map { |policy| policy.fetch("resource") }
      result = nil

      queries = capture_sql_queries do
        assert_enqueued_with(job: SyncJob) { result = command(context).call }
      end

      assert_no_financial_sql(queries)
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal link, context.link.reload.attributes
      assert_equal evidence, retained_evidence(context)
      assert_equal policies, Account::SourcePolicy.where(account: context.account).order(:resource).map(&:attributes)
      connection = context.control.provider_connection.reload
      receipt = context.control.reload.audit_results.fetch("native_cutover")
      assert_equal preparation.run_id, receipt.fetch("preparation_run_id")
      assert_equal({ context.external.id => "2026-09-08" }, receipt.fetch("account_starts"))
      assert_equal "2026-09-08", context.external.reload.metadata.fetch("mercury_initial_history_start")
      assert context.control.active?
      assert connection.good?
      assert_equal 1, connection.writer_epoch
      assert_equal 1, context.control.writer_epoch
      sync = connection.syncs.sole
      assert_equal result.sync_id, sync.id
      assert_nil sync.window_start_date
      assert_raises(Provider::AccountData::LegacyWriterFence::OwnershipChanged) do
        MercuryItem::Importer.new(context.item).import
      end

      client = Client.new(context.source.account_id, rows) { assert_equal 0, ApplicationRecord.connection.open_transactions }
      Provider::Mercury.stubs(:new).returns(client)
      original_mapping = SourceRecord.where(external_account: context.external).sole.entry_source.attributes
      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        Provider::AccountData::Syncer.new(connection).perform_sync(sync)
      end
      assert_equal "2026-09-08", Time.iso8601(client.requests.sole.fetch(:start)).to_date.iso8601
      assert_equal original_entry.id, context.account.entries.sole.id
      assert_equal financial.fetch("entries"), identity_financial_snapshot(context).fetch("entries")
      assert_equal original_mapping, SourceRecord.where(external_account: context.external).sole.entry_source.attributes
      assert connection.provider_sync_checkpoints.find_by!(stream: "transactions").ingestion_batch.applied?
    end
  end

  test "production readiness still rejects Mercury before mutating a prepared connection" do
    with_source do |context, _rows|
      finish_preparation(context)
      Provider::AccountData::Mercury.unstub(:native_ready?)
      refute Provider::AccountData::Mercury.native_ready?
      before = ownership(context)

      assert_no_enqueued_jobs do
        assert_raises(Provider::AccountData::UnsupportedCapability) { command(context).call }
      end

      assert_equal before, ownership(context)
      assert_paused(context)
    end
  end

  test "an account with a second provider needs explicit choices before Mercury identity preparation" do
    with_source do |context, _rows|
      other = create_provider_connection(family: context.family, provider_key: "up")
      other_external = create_external_account(other)
      other_link = AccountProvider.create!(account: context.account, external_account: other_external)
      begin
        assert_raises(Selection::Conflict) { finish_preparation(context) }
        assert_empty Account::SourcePolicy.where(account: context.account)
        assert_empty SourceRecord.where(external_account: context.external)

        transaction_policy = Account::SourcePolicy.select!(account: context.account, account_provider: context.link.reload, resource: "transactions")
        balance_policy = Account::SourcePolicy.select!(account: context.account, account_provider: other_link, resource: "balances")
        original = Account::SourcePolicy.where(account: context.account).order(:id).map(&:attributes)
        finish_preparation(context)
        command(context).call

        assert_equal original, Account::SourcePolicy.where(account: context.account).order(:id).map(&:attributes)
        assert transaction_policy.reload.active?
        assert balance_policy.reload.active?
      ensure
        Account::SourcePolicy.where(account_provider: other_link).delete_all
        other_link.delete
        other.destroy!
      end
    end
  end

  test "a changed retained Mercury cache cannot activate from an old preparation receipt" do
    with_source do |context, _rows|
      finish_preparation(context)
      context.source.update!(raw_transactions_payload: [])
      financial = identity_financial_snapshot(context)
      evidence = retained_evidence(context)

      assert_no_enqueued_jobs do
        assert_raises(Provider::AccountData::MigrationCopier::SourceChanged, Provider::AccountData::MigrationCopier::Conflict,
          Preparation::Conflict, Cutover::Conflict) { command(context).call }
      end

      assert_equal financial, identity_financial_snapshot(context)
      assert_equal evidence, retained_evidence(context)
      assert_paused(context)
    end
  end

  test "failed Sync installation rolls back Mercury ownership and initial history metadata" do
    with_source do |context, _rows|
      finish_preparation(context)
      before = ownership(context)
      external_before = context.external.reload.attributes
      connection_id = context.control.provider_connection_id
      failure = ->(sync) { raise IOError, "Cutover interrupted" if sync.syncable_type == "ProviderConnection" && sync.syncable_id == connection_id }
      Sync.set_callback(:create, :before, failure)
      begin
        assert_no_enqueued_jobs { assert_raises(IOError) { command(context).call } }
      ensure
        Sync.skip_callback(:create, :before, failure)
      end

      assert_equal before, ownership(context)
      assert_equal external_before, context.external.reload.attributes
      assert_paused(context)
    end
  end

  test "dispatch recovery reuses the committed Mercury Sync outside the cutover transaction" do
    with_source do |context, _rows|
      finish_preparation(context)
      failure = ->(*) { raise IOError, "Queue unavailable" }
      assert_raises(IOError) { SyncJob.stub(:perform_later, failure) { command(context).call } }
      original = context.control.provider_connection.syncs.sole
      dispatch = lambda do |sync|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal original.id, sync.id
      end

      result = SyncJob.stub(:perform_later, dispatch) { command(context).call }

      assert result.replayed
      assert_equal original.id, result.sync_id
      assert_equal [ original.id ], context.control.provider_connection.syncs.pluck(:id)
    end
  end

  private
    def command(context)
      Cutover.new(provider_key: "mercury", legacy_item_id: context.item.id, family: context.family, page_size: 1)
    end

    def finish_preparation(context)
      150.times do
        result = Preparation.new(provider_key: "mercury", legacy_item_id: context.item.id, family: context.family, page_size: 1).run
        return result if result.awaiting_acceptance?
      end
      flunk "Mercury preparation did not complete"
    end

    def with_source
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = MercuryItem.create!(family: family, name: "Mercury cutover", token: "private-mercury-token")
        account = family.accounts.create!(name: "Existing Mercury account", currency: "USD", balance: 100,
          accountable: Depository.new, status: "active")
        begin
          rows = [ { "id" => "original", "amount" => "-12.50", "status" => "sent", "bankDescription" => "Original expense",
            "createdAt" => "2026-09-12T12:00:00Z", "postedAt" => "2026-09-13T12:00:00Z" } ]
          source = item.mercury_accounts.create!(account_id: "remote-mercury", name: "Checking", currency: "USD",
            current_balance: 100, created_at: Time.utc(2026, 9, 10), raw_transactions_payload: rows)
          link = AccountProvider.create!(account: account, provider: source)
          assert MercuryEntry::Processor.new(rows.sole, mercury_account: source).process
          item.syncs.create!(status: "completed", completed_at: Time.utc(2026, 9, 15), created_at: Time.utc(2026, 9, 15))
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "mercury", legacy_item_id: item.id, batch_size: 1)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          context = IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: control, mapping: mapping, external: external)
          yield context, rows
        ensure
          connection = ProviderMigrationControl.find_by(legacy_type: "MercuryItem", legacy_id: item.id)&.provider_connection
          if connection
            connection.update_columns(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil)
          end
          Sync.where(syncable_type: "MercuryItem", syncable_id: item.id).delete_all
          cleanup_identity_source(item, account)
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all if connection
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end

    def ownership(context)
      { control: context.control.reload.attributes, connection: context.control.provider_connection.reload.attributes,
        syncs: context.control.provider_connection.syncs.order(:id).map(&:attributes) }
    end

    def retained_evidence(context)
      { batches: context.control.provider_connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text")),
        observations: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        mappings: EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes) }
    end

    def assert_paused(context)
      assert context.control.reload.quiescing?
      connection = context.control.provider_connection.reload
      assert connection.disabled?
      assert_equal 0, connection.writer_epoch
      assert_equal 0, context.control.writer_epoch
      assert_empty connection.syncs
    end
end
