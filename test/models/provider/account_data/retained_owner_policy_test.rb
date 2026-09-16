require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::RetainedOwnerPolicyTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Owners = Provider::AccountData::RetiredOwner
  Policy = Account::SourcePolicy
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    Provider::AccountData::Up.stubs(:native_ready?).returns(true)
    Provider::Up.expects(:new).never
  end

  teardown do
    clear_enqueued_jobs
  end

  test "actual cutover and owner preparation capture immutable exact relational witnesses without rewriting archives" do
    with_native_copy do |context|
      archives = archived_bytes(context)
      original = mappings(context).to_h { |mapping| [ mapping.id, mapping.attributes.except("updated_at", "retained_owner") ] }

      Owners.prepare!(control: context.control, family: context.family)

      mappings(context).each do |mapping|
        assert_equal projection(context, mapping), mapping.retained_owner
        assert_equal Owners::KEYS.sort, mapping.retained_owner.keys.sort
        assert_equal original.fetch(mapping.id), mapping.attributes.except("updated_at", "retained_owner")
      end
      assert_equal archives, archived_bytes(context)
      assert_empty context.account.entries
      assert_equal mappings(context).map(&:id), Owners.prepare!(control: context.control.reload, family: context.family).sort
    end
  end

  test "raw first capture requires the matching native cutover receipt and epochs" do
    with_native_copy do |context|
      control = context.control.reload
      audit = control.audit_results.deep_dup
      [
        { state: "quiescing" },
        { writer_epoch: 2 },
        { copy_version: 2 },
        { audit_results: audit.merge("snapshot_checksums_verified" => false) },
        { audit_results: audit.merge("copy_mode" => "shadow") },
        { audit_results: audit.merge("declared_writer_fence_held" => false) },
        { audit_results: audit.except("native_cutover") },
        { audit_results: audit.deep_merge("native_cutover" => { "copy_run_id" => SecureRandom.uuid }) },
        { audit_results: audit.deep_merge("native_cutover" => { "connection_id" => SecureRandom.uuid }) },
        { audit_results: audit.deep_merge("native_cutover" => { "writer_epoch" => 2 }) }
      ].each do |change|
        assert_database_failure do
          ProviderMigrationControl.where(id: control.id).update_all(change)
          raw_capture(context, context.mapping)
        end
      end
      assert_database_failure do
        ProviderConnection.where(id: control.provider_connection_id).update_all(writer_epoch: 0)
        raw_capture(context, context.mapping)
      end
      assert_nil context.mapping.reload.retained_owner
    end
  end

  test "raw first capture refuses forged projection identities checksums copy versions shapes and oversized values" do
    with_native_copy do |context|
      expected = projection(context, context.mapping)
      [
        expected.merge("family_id" => SecureRandom.uuid), expected.merge("mapping_id" => SecureRandom.uuid),
        expected.merge("control_id" => SecureRandom.uuid), expected.merge("provider_connection_id" => SecureRandom.uuid),
        expected.merge("legacy_id" => SecureRandom.uuid), expected.merge("legacy_item_id" => SecureRandom.uuid),
        expected.merge("legacy_item_type" => "MercuryItem"), expected.merge("role" => "connection"),
        expected.merge("source_checksum" => "v1-#{'0' * 64}"), expected.merge("copy_run_id" => SecureRandom.uuid),
        expected.merge("copy_version" => "1"), expected.except("source_checksum"),
        expected.merge("extra" => "unexpected"), expected.merge("extra" => "x" * 16_385), []
      ].each do |value|
        assert_database_failure { raw_capture(context, context.mapping, value: value) }
      end
      assert_nil context.mapping.reload.retained_owner
    end
  end

  test "raw first capture requires copied and verified provenance and the original live legacy rows" do
    with_native_copy do |context|
      [ :copied_at, :verified_at ].each do |column|
        assert_database_failure do
          ProviderMigrationMapping.where(id: context.mapping.id).update_all(column => nil)
          raw_capture(context, context.mapping)
        end
      end
      assert_database_failure do
        UpAccount.where(id: context.source.id).delete_all
        raw_capture(context, context.mapping)
      end
      assert_database_failure do
        UpAccount.where(id: context.source.id).delete_all
        UpItem.where(id: context.item.id).delete_all
        raw_capture(context, item_mapping(context))
      end
      assert_database_failure do
        other = UpItem.create!(family: context.family, name: "Different source parent", access_token: "private-other-token")
        UpAccount.where(id: context.source.id).update_all(up_item_id: other.id)
        raw_capture(context, context.mapping)
      end
      assert_database_failure do
        UpItem.where(id: context.item.id).update_all(family_id: families(:empty).id)
        raw_capture(context, context.mapping)
      end
    end
  end

  test "captured mapping identity and verified copy provenance cannot change or be cleared by SQL" do
    with_native_copy(capture: true) do |context|
      mapping = context.mapping.reload
      [
        { retained_owner: nil }, { retained_owner: mapping.retained_owner.merge("copy_version" => 999) },
        { legacy_id: SecureRandom.uuid }, { legacy_type: "MercuryAccount" },
        { source_checksum: "v1-#{'0' * 64}" }, { source_version: "replaced" },
        { copied_at: nil }, { verified_at: nil }, { created_at: 1.day.ago }
      ].each do |change|
        assert_database_failure { ProviderMigrationMapping.where(id: mapping.id).update_all(change) }
      end
      ProviderMigrationMapping.where(id: mapping.id).update_all(retained_owner: mapping.retained_owner, updated_at: Time.current)
      assert_equal mapping.retained_owner, mapping.reload.retained_owner
    end
  end

  test "new policy revision accepts exact retired dual origins after both compatibility rows are deleted" do
    with_native_copy(capture: true) do |context|
      original = balances_policy(context)
      binding = original.source_binding.deep_dup
      archives = archived_bytes(context)
      financial = identity_financial_snapshot(context)
      retire_rows(context)

      policy = insert_policy(context, binding: binding)

      assert_equal binding, policy.source_binding
      assert_equal context.link.id, policy.account_provider_id
      assert_equal original.revision + 1, policy.revision
      assert_equal archives, archived_bytes(context)
      assert_equal financial, identity_financial_snapshot(context)
      assert_equal binding, original.reload.source_binding
      refute original.active?
    end
  end

  test "missing account with still live original item requires the same retired paired witnesses" do
    with_native_copy(capture: true) do |context|
      binding = balances_policy(context).source_binding
      context.control.update!(state: "retired")
      UpAccount.where(id: context.source.id).delete_all

      assert_equal binding, insert_policy(context, binding: binding).source_binding
      assert UpItem.exists?(context.item.id)
    end
  end

  test "policy insertion refuses missing either witness and refuses a missing source under active ownership" do
    [ nil, "connection", "external_account", "active" ].each do |mode|
      with_native_copy do |context|
        binding = balances_policy(context).source_binding
        if mode == "active"
          Owners.prepare!(control: context.control, family: context.family)
        elsif mode
          mapping = mode == "connection" ? item_mapping(context) : context.mapping
          Fence.with_exclusive(context.item) do
            ApplicationRecord.transaction do
              Owners.capture!(mapping: mapping, family: context.family)
            end
          end
        end
        retire_rows(context, state: mode == "active" ? "active" : "retired")

        assert_database_failure { insert_policy(context, binding: binding) }
        assert balances_policy(context).active?
      end
    end
  end

  test "retained policy fallback cannot hide contradictory live legacy parent or family" do
    with_native_copy(capture: true) do |context|
      binding = balances_policy(context).source_binding
      context.control.update!(state: "retired")
      assert_database_failure do
        other = UpItem.create!(family: context.family, name: "Different live parent", access_token: "private-other-token")
        UpAccount.where(id: context.source.id).update_all(up_item_id: other.id)
        insert_policy(context, binding: binding)
      end
      assert_database_failure do
        UpItem.where(id: context.item.id).update_all(family_id: families(:empty).id)
        insert_policy(context, binding: binding)
      end
      assert balances_policy(context).active?
    end
  end

  test "retained policy insertion rejects changed current cutover context and forged shared tuples" do
    with_native_copy(capture: true) do |context|
      binding = balances_policy(context).source_binding.deep_dup
      retire_rows(context)
      audit = context.control.reload.audit_results.deep_dup
      [
        audit.except("native_cutover"), audit.merge("copy_run_id" => SecureRandom.uuid),
        audit.deep_merge("native_cutover" => { "writer_epoch" => 2 })
      ].each do |changed|
        assert_database_failure do
          ProviderMigrationControl.where(id: context.control.id).update_all(audit_results: changed)
          insert_policy(context, binding: binding)
        end
      end
      %w[legacy_item_id external_account_id provider_connection_id].each do |key|
        assert_database_failure { insert_policy(context, binding: binding.merge(key => SecureRandom.uuid)) }
      end
      assert balances_policy(context).active?
    end
  end

  test "existing policy immutability and one way deactivation survive the retained insertion exception" do
    with_native_copy(capture: true) do |context|
      original = balances_policy(context)
      retire_rows(context)
      current = insert_policy(context, binding: original.source_binding)

      assert_database_failure { Policy.where(id: original.id).update_all(active: true) }
      assert_database_failure { Policy.where(id: current.id).update_all(source_binding: {}) }
      Policy.where(id: current.id).update_all(active: false)
      assert_database_failure { Policy.where(id: current.id).update_all(active: true) }
    end
  end

  private
    def with_native_copy(capture: false)
      family = families(:dylan_family)
      activity = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
      with_identity_source do |context|
        prepared = nil
        150.times do
          prepared = Provider::AccountData::MigrationPreparation.new(provider_key: "up", legacy_item_id: context.item.id,
            family: context.family, page_size: 1).run
          break if prepared.awaiting_acceptance?
        end
        assert prepared.awaiting_acceptance?
        result = Provider::AccountData::MigrationCutover.new(provider_key: "up", legacy_item_id: context.item.id,
          family: context.family, page_size: 1).call
        # Keep the actual cutover receipt but never execute its queued provider request.
        Sync.find(result.sync_id).update!(status: "failed", completed_at: Time.current)
        context.control.reload
        Owners.prepare!(control: context.control, family: context.family) if capture
        yield context
      ensure
        Sync.where(syncable_type: "ProviderConnection", syncable_id: context.control.provider_connection_id).delete_all
      end
    ensure
      Family.where(id: family.id).update_all(activity) if family && activity
      clear_enqueued_jobs
    end

    def mappings(context)
      context.control.provider_migration_mappings.where(role: %w[connection external_account]).order(:id).to_a
    end

    def item_mapping(context)
      context.control.provider_migration_mappings.find_by!(role: "connection")
    end

    def projection(context, mapping)
      control = context.control.reload
      { "format" => Owners::FORMAT, "family_id" => context.family.id, "control_id" => control.id,
        "provider_connection_id" => control.provider_connection_id, "mapping_id" => mapping.id, "role" => mapping.role,
        "legacy_type" => mapping.legacy_type, "legacy_id" => mapping.legacy_id,
        "legacy_item_type" => control.legacy_type, "legacy_item_id" => control.legacy_id,
        "source_checksum" => mapping.source_checksum, "copy_run_id" => control.high_water_mark.fetch("copy_run_id"),
        "copy_version" => control.copy_version }
    end

    def raw_capture(context, mapping, value: projection(context, mapping))
      ProviderMigrationMapping.where(id: mapping.id).update_all(retained_owner: value)
    end

    def balances_policy(context)
      Policy.find_by!(account_id: context.account.id, resource: "balances", active: true)
    end

    def insert_policy(context, binding:)
      ApplicationRecord.transaction(requires_new: true) do
        previous = balances_policy(context)
        previous.update!(active: false)
        id = SecureRandom.uuid
        Policy.insert_all!([ { id: id, account_id: context.account.id, family_id: context.family.id,
          account_provider_id: context.link.id, resource: "balances", revision: previous.revision + 1,
          active: true, source_binding: binding, created_at: Time.current, updated_at: Time.current } ])
        Policy.find(id)
      end
    end

    def retire_rows(context, state: "retired")
      context.control.update!(state: state)
      # This exercises schema admission, not a production retirement command.
      # Model destroy would also remove the AccountProvider and is not used.
      UpAccount.where(id: context.source.id).delete_all
      UpItem.where(id: context.item.id).delete_all
    end

    def archived_bytes(context)
      context.control.provider_connection.ingestion_batches.where(origin_kind: "migration").order(:id)
        .pluck(:id, Arel.sql("payload::text"))
    end

    def assert_database_failure(&block)
      assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true, &block)
      end
    end
end
