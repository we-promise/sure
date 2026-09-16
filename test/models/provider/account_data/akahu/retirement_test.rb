require "test_helper"
require_relative "../../../../support/akahu_migration_test_helper"

class Provider::AccountData::Akahu::RetirementTest < ActiveSupport::TestCase
  include AkahuMigrationTestHelper
  self.use_transactional_tests = false

  Retirement = Provider::AccountData::MigrationRetirement
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    Account.any_instance.stubs(:sync_later)
    Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
    Provider::Akahu.expects(:new).never
  end
  teardown { clear_enqueued_jobs }

  test "actual Akahu retirement preserves financial UUIDs signed identities original Sync history and logo bytes" do
    with_akahu_migration_source(logo: true) do |context|
      entry = context.account.entries.find_by!(source: "akahu", external_id: "akahu_retirement-transaction")
      entry.update_columns(import_locked: true, user_modified: true)
      original = context.item.syncs.sole
      child = context.account.syncs.create!(parent: original, status: "completed", completed_at: Time.current)
      before = retained_state(context)
      old_attachment_id = context.item.logo_attachment.id
      shared_attachment = context.connection.reload.logo_attachment.attributes
      blob = context.blob.reload.attributes
      mappings = mapping_state(context)
      result = nil

      queries = capture_sql_queries do
        assert_no_enqueued_jobs { result = command(context).call }
      end

      refute result.replayed
      assert_equal [ context.control.id, context.connection.id ], [ result.control_id, result.connection_id ]
      refute AkahuItem.exists?(context.item.id)
      refute AkahuAccount.exists?(context.source.id)
      assert context.control.reload.retired?
      assert_equal before, retained_state(context)
      assert_equal mappings, mapping_state(context)
      assert_no_financial_sql(queries)
      refute ActiveStorage::Attachment.exists?(old_attachment_id)
      assert_equal shared_attachment, context.connection.reload.logo_attachment.attributes
      assert_equal blob, context.blob.reload.attributes
      assert_equal context.logo_bytes, context.blob.download.b
      assert_equal context.logo_bytes, Provider::AccountData::AuxiliaryCopier.for(control: context.control).each_archived_chunk.to_a.join.b
      assert_equal original.id, child.reload.parent_id
      assert_includes Sync.for_family(context.family).pluck(:id), original.id
      assert_includes Sync.for_family(context.family).pluck(:id), child.id
      assert_bootstrap_identity(context, entry.id)
      receipt = context.control.audit_results.fetch("native_retirement")
      refute_includes receipt.to_json, "private-akahu-retirement"
      assert_equal %w[connection external_account], context.control.provider_migration_mappings.map(&:role).sort
      assert context.control.provider_migration_mappings.all? { |mapping| mapping.retained_owner.present? }

      Fence.expects(:with_exclusive).never
      assert_no_enqueued_jobs { assert command(context).call.replayed }
      assert_equal receipt, context.control.reload.audit_results.fetch("native_retirement")
      assert_equal before, retained_state(context)
    end
  end

  test "retired Akahu policy verification and new revisions retain the original dual source" do
    with_akahu_migration_source do |context|
      command(context).call
      originals = Account::SourcePolicy.where(account: context.account).order(:resource).to_a
      originals.each { |policy| assert Account::SourcePolicy::Binding.verify_live!(policy: policy) }
      before = retained_state(context).except(:policies)
      balance = originals.find { |policy| policy.resource == "balances" }
      Account::SourcePolicy.where(id: balance.id).update_all(active: false)

      replacement = Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "balances")

      assert_equal balance.revision + 1, replacement.revision
      assert_equal balance.source_binding, replacement.source_binding
      assert_equal context.item.id, replacement.source_binding.fetch("legacy_item_id")
      assert_equal context.source.id, replacement.source_binding.fetch("legacy_account_id")
      assert Account::SourcePolicy::Binding.verify_live!(policy: replacement)
      assert_equal before, retained_state(context).except(:policies)
    end
  end

  test "unfinished item source financial account or native work prevents Akahu retirement" do
    %i[item source account connection].each do |owner|
      with_akahu_migration_source do |context|
        pending = Sync.create!(syncable: context.public_send(owner))
        before = retained_state(context)

        assert_no_enqueued_jobs { assert_raises(Retirement::Busy) { command(context).call } }

        assert_live(context)
        assert_equal before, retained_state(context)
        pending.update!(status: "failed", completed_at: Time.current)
        command(context).call
        assert_equal "failed", pending.reload.status
      end
    end
  end

  test "an active native lease blocks removal before ownership witnesses" do
    with_akahu_migration_source do |context|
      connection = context.connection
      connection.update!(lease_owner: "retirement-blocker", lease_expires_at: 1.minute.from_now)
      before = retained_state(context)

      assert_raises(Retirement::Busy) { command(context).call }

      assert_live(context)
      assert_equal before, retained_state(context)
      assert context.control.provider_migration_mappings.all? { |mapping| mapping.retained_owner.nil? }
    end
  end

  test "new uncopied Akahu source and cache or either credential drift refuse removal" do
    %i[source cache app_token user_token].each do |change|
      with_akahu_migration_source do |context|
        case change
        when :source
          context.item.akahu_accounts.create!(account_id: "uncopied", name: "Uncopied", currency: "NZD", raw_transactions_payload: [])
        when :cache
          context.source.update_columns(raw_transactions_payload: [ akahu_migration_transaction("description" => "Uncaptured") ])
        else
          context.item.update_columns(change => "changed-private-token")
        end
        before = retained_state(context)

        error = assert_raises(Retirement::Conflict) { command(context).call }

        refute_includes error.message, "changed-private-token"
        assert_live(context)
        assert_equal before, retained_state(context)
      end
    end
  end

  test "unreviewed item or source attachments are never orphaned or purged" do
    %i[item source].each do |owner|
      with_akahu_migration_source(logo: true) do |context|
        record = context.public_send(owner)
        # Unknown attachment names are possible stored rows, not declarations
        # that may run ActiveStorage's attachment-specific callbacks.
        ActiveStorage::Attachment.insert_all!([ { name: "unreviewed", record_type: record.class.name,
          record_id: record.id, blob_id: context.blob.id, created_at: Time.current } ])
        attachments = ActiveStorage::Attachment.where(blob_id: context.blob.id).order(:id).map(&:attributes)
        before = retained_state(context)

        assert_no_enqueued_jobs { assert_raises(Retirement::Conflict) { command(context).call } }

        assert_live(context)
        assert_equal attachments, ActiveStorage::Attachment.where(blob_id: context.blob.id).order(:id).map(&:attributes)
        assert_equal context.logo_bytes, context.blob.download.b
        assert_equal before, retained_state(context)
      end
    end
  end

  test "invalid original archive refuses removal and retired source policy use without reconstructing proof" do
    [ false, true ].each do |retired|
      with_akahu_migration_source do |context|
        command(context).call if retired
        batch = context.connection.ingestion_batches.find_by!(stream: "legacy_snapshot", external_account_id: context.external.id, sequence: 0)
        original = IngestionBatch.where(id: batch.id).pick(Arel.sql("payload::text"))
        IngestionBatch.where(id: batch.id).update_all(payload: { "changed" => true })
        before = retained_state(context)
        begin
          assert_raises(Retirement::Conflict) { command(context).call }
          if retired
            policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "balances")
            assert_raises(Account::SourcePolicy::Binding::Conflict) { Account::SourcePolicy::Binding.verify_live!(policy: policy) }
            Account::SourcePolicy.where(id: policy.id).update_all(active: false)
            assert_no_difference "Account::SourcePolicy.count" do
              assert_raises(Account::SourcePolicy::Binding::Conflict) do
                Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "balances")
              end
            end
            assert_equal before.except(:policies), retained_state(context).except(:policies)
          else
            assert_live(context)
            assert_equal before, retained_state(context)
          end
        ensure
          IngestionBatch.where(id: batch.id).update_all([ "payload = ?", original ])
        end
        assert command(context).call.replayed if retired
      end
    end
  end

  test "failure after physical deletes rolls back sources logo and every new ownership witness" do
    with_akahu_migration_source(logo: true) do |context|
      before = retained_state(context)
      source_attachment = context.item.logo_attachment.attributes
      fail_retirement = -> { raise IOError, "Simulated retirement commit failure" if id == context.control.id && retired? }
      ProviderMigrationControl.set_callback(:update, :after, fail_retirement)
      begin
        assert_no_enqueued_jobs { assert_raises(IOError) { command(context).call } }
      ensure
        ProviderMigrationControl.skip_callback(:update, :after, fail_retirement)
      end

      assert_live(context)
      assert context.control.provider_migration_mappings.all? { |mapping| mapping.retained_owner.nil? }
      assert_equal source_attachment, ActiveStorage::Attachment.find(source_attachment.fetch("id")).attributes
      assert_equal before, retained_state(context)
      refute command(context).call.replayed
    end
  end

  test "replay preserves later pending native work but rejects a changed signed receipt" do
    with_akahu_migration_source do |context|
      command(context).call
      pending = context.connection.syncs.create!
      before = retained_state(context)
      assert_no_enqueued_jobs { assert command(context).call.replayed }
      assert_equal before, retained_state(context)
      assert pending.reload.pending?
      audit = context.control.reload.audit_results.deep_dup
      altered = audit.deep_dup
      altered.fetch("native_retirement")["retired_at"] = "2020-01-01T00:00:00Z"
      context.control.update!(audit_results: altered)

      assert_no_enqueued_jobs { assert_raises(Retirement::Conflict) { command(context).call } }

      assert_equal before, retained_state(context)
    end
  end

  test "production readiness and exact family remain required before Akahu retirement" do
    with_akahu_migration_source do |context|
      Provider::AccountData::Akahu.unstub(:native_ready?)
      refute Provider::AccountData::Akahu.native_ready?
      assert_raises(Provider::AccountData::UnsupportedCapability) { command(context).call }
      Provider::AccountData::Akahu.stubs(:native_ready?).returns(true)
      other = Family.create!(name: "Other Akahu retirement family")
      begin
        assert_raises(Retirement::Conflict) do
          Retirement.new(provider_key: "akahu", legacy_item_id: context.item.id, family: other).call
        end
      ensure
        other.destroy!
      end
      assert_live(context)
    end
  end

  private
    def command(context)
      Retirement.new(provider_key: "akahu", legacy_item_id: context.item.id, family: context.family)
    end

    def assert_live(context)
      assert AkahuItem.exists?(context.item.id)
      assert AkahuAccount.exists?(context.source.id)
      assert context.control.reload.active?
      assert_nil context.control.audit_results["native_retirement"]
    end

    def mapping_state(context)
      context.control.provider_migration_mappings.order(:id).map { |mapping| mapping.attributes.except("retained_owner", "updated_at") }
    end

    def assert_bootstrap_identity(context, entry_id)
      posting = EntrySource.find_by!(bootstrap_external_account: context.external, entry_identity: entry_id, role: "posting")
      evidence = Ingestion::LegacyIdentityEvidence.for_mapping!(entry_source: posting, source_record: posting.source_record)
      assert_equal entry_id, evidence.fetch(:row).fetch("entry_id")
      assert_equal posting.source_record.external_id, evidence.fetch(:identity).fetch("external_id")
      assert_equal context.account.id, posting.account_id
    end

    def retained_state(context)
      { financial: identity_financial_snapshot(context),
        links: AccountProvider.where(account: context.account).order(:id).map(&:attributes),
        policies: Account::SourcePolicy.where(account: context.account).order(:id).map(&:attributes),
        external: context.external.reload.attributes, connection: context.connection.reload.attributes,
        batches: context.connection.ingestion_batches.order(:id).pluck(:id, Arel.sql("payload::text")),
        checkpoints: context.connection.provider_sync_checkpoints.order(:id).pluck(:id, Arel.sql("state::text")),
        observations: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        postings: EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes),
        bindings: ProviderMigrationAccountBinding.where(provider_migration_mapping_id: context.control.provider_migration_mappings.select(:id)).order(:id).map(&:attributes),
        syncs: Sync.for_family(context.family).or(Sync.where(syncable_type: "AkahuAccount", syncable_id: context.source.id)).order(:id).map(&:attributes) }
    end
end
