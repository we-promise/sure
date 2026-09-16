require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Family::RetainedProviderSyncHistoryTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
  end

  teardown do
    clear_enqueued_jobs
  end

  test "physical legacy row removal preserves exact original Sync history and ancestry" do
    with_copied_owner do |family, item, source, control, parent, child|
      originals = Sync.where(id: [ parent.id, child.id ]).order(:id).map(&:attributes)
      control.update!(state: "retired")
      remove_legacy_rows(item, source)
      control.provider_connection.update!(writer_epoch: 2)
      IngestionBatch.any_instance.expects(:payload).never

      assert_no_enqueued_jobs do
        history = Sync.for_family(family).where(id: [ parent.id, child.id ]).order(:id)
        assert_equal originals, history.map(&:attributes)
        assert_equal [ child.id ], parent.reload.children.ids
        assert_equal parent.id, child.reload.parent_id
        assert_equal "UpItem", parent.syncable_type
        assert_equal item.id, parent.syncable_id
        assert_nil parent.reload.syncable
        assert_includes Sync.for_family(family).ids, control.provider_connection.syncs.sole.id

        scheduled = Family::ProviderSyncables.new(family).scheduling_scopes.flat_map(&:to_a)
        assert_includes scheduled, control.provider_connection
        refute scheduled.any? { |owner| owner.is_a?(UpItem) && owner.id == item.id }
      end
    end
  end

  test "live legacy history remains visible without a retirement witness" do
    with_copied_owner(capture: false) do |family, _item, _source, control, parent, child|
      assert_nil connection_mapping(control).retained_owner
      assert_equal [ parent.id, child.id ].sort, Sync.for_family(family).where(id: [ parent.id, child.id ]).ids.sort
      assert_empty Family::ProviderSyncables.new(family).retained_history_scope
    end
  end

  test "deleted legacy owners without a witness are excluded even when the control is retired" do
    with_copied_owner(capture: false) do |family, item, source, control, parent, child|
      control.update!(state: "retired")
      remove_legacy_rows(item, source)

      assert_empty Sync.for_family(family).where(id: [ parent.id, child.id ])
      assert_equal [ control.provider_connection.syncs.sole.id ], Sync.for_family(family).ids
      assert_equal 2, Sync.where(id: [ parent.id, child.id ]).count
    end
  end

  test "a captured witness exposes a missing original owner only after retirement and only to its family" do
    with_copied_owner do |family, item, source, control, parent, child|
      remove_legacy_rows(item, source)
      assert_empty Sync.for_family(family).where(id: [ parent.id, child.id ])
      control.update!(state: "retired")

      assert_equal [ parent.id, child.id ].sort, Sync.for_family(family).where(id: [ parent.id, child.id ]).ids.sort
      assert_empty Sync.for_family(families(:empty)).where(id: [ parent.id, child.id ])
      assert_empty Sync.for_family(family, resource_owner: users(:family_admin)).where(id: [ parent.id, child.id ])
    end
  end

  test "changing the control cutover receipt cannot relabel an original retained owner" do
    with_copied_owner do |family, item, source, control, parent, child|
      control.update!(state: "retired")
      remove_legacy_rows(item, source)
      original = control.audit_results.deep_dup
      [
        { "native_cutover" => { "copy_run_id" => SecureRandom.uuid } },
        { "copy_run_id" => SecureRandom.uuid },
        { "native_cutover" => { "connection_id" => SecureRandom.uuid } },
        { "native_cutover" => { "writer_epoch" => "1" } }
      ].each do |changed|
        control.update!(audit_results: original.deep_merge(changed))
        assert_empty Sync.for_family(family).where(id: [ parent.id, child.id ])
      end
      assert_equal "UpItem", parent.reload.syncable_type
      assert_equal item.id, child.reload.syncable_id
      control.update!(audit_results: original)
      assert_equal [ parent.id, child.id ].sort, Sync.for_family(family).where(id: [ parent.id, child.id ]).ids.sort
    end
  end

  private
    def with_copied_owner(capture: true)
      with_provider_encryption do
        family = Family.create!(name: "Retained provider Sync history")
        item = family.up_items.create!(name: "Original Up owner", access_token: "private-retained-history-token")
        source = item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Unlinked checking", currency: "USD",
          current_balance: 100, raw_transactions_payload: [])
        parent = item.syncs.create!(status: "completed", completed_at: 2.days.ago)
        child = item.syncs.create!(parent: parent, status: "failed", failed_at: 2.days.ago,
          error: "Original bounded failure", data: { "original" => "legacy" })
        preparation = nil
        150.times do
          preparation = Provider::AccountData::MigrationPreparation.new(provider_key: "up", legacy_item_id: item.id,
            family: family, page_size: 1).run
          break if preparation.awaiting_acceptance?
        end
        assert preparation.awaiting_acceptance?
        result = Provider::AccountData::MigrationCutover.new(provider_key: "up", legacy_item_id: item.id,
          family: family, page_size: 1).call
        control = ProviderMigrationControl.find(result.control_id)
        # This fixture has no native observations. Settle the generated work so
        # witness capture can run; this is not a claim that a provider fetch ran.
        Sync.find(result.sync_id).update_columns(status: "completed", completed_at: Time.current)
        Provider::AccountData::RetiredOwner.prepare!(control: control, family: family) if capture
        clear_enqueued_jobs
        yield family, item, source, control.reload, parent, child
      ensure
        cleanup_owner(family, item) if family
      end
    end

    def connection_mapping(control)
      control.provider_migration_mappings.find_by!(role: "connection")
    end

    def remove_legacy_rows(item, source)
      # Deliberately callback-free test disposal. Normal item destruction would
      # delete Sync ancestry; witness capture itself is not a retirement command.
      UpAccount.where(id: source.id).delete_all
      UpItem.where(id: item.id).delete_all
      refute UpAccount.exists?(source.id)
      refute UpItem.exists?(item.id)
    end

    def cleanup_owner(family, item)
      connections = family.provider_connections.to_a
      ProviderMigrationAccountBinding.where(family_id: family.id).delete_all
      ProviderSyncCheckpoint.where(family_id: family.id).delete_all
      IngestionBatch.where(family_id: family.id).delete_all
      ProviderSyncGeneration.where(family_id: family.id).delete_all
      ProviderMigrationMapping.where(family_id: family.id).delete_all
      ProviderMigrationControl.where(family_id: family.id).delete_all
      # Query original owner tuples directly, including those no longer visible
      # after their retirement mapping was removed during fixture teardown.
      Sync.where(syncable_type: "UpItem", syncable_id: item.id).delete_all if item
      Sync.where(syncable_type: "ProviderConnection", syncable_id: connections.map(&:id)).delete_all
      connections.each(&:destroy!)
      UpAccount.where(up_item_id: item.id).delete_all if item
      UpItem.where(id: item.id).delete_all if item
      family.destroy!
    end
end
