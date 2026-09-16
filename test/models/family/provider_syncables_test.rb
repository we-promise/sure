require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Family::ProviderSyncablesTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "scheduling follows ownership through copy cutover rollback and retirement" do
    with_provider_encryption do
      family = families(:dylan_family)
      item = family.up_items.create!(name: "Migrating Up", access_token: "private-up-token")
      connection = create_provider_connection(family: family)
      control = ProviderMigrationControl.create!(family: family, provider_connection: connection,
        provider_key: "up", legacy_type: "UpItem", legacy_id: item.id)
      catalog = Family::ProviderSyncables.new(family)

      {
        "legacy" => [ item ], "copying" => [ item ], "shadow" => [ item ], "failed" => [ item ],
        "quiescing" => [], "active" => [ connection ], "rollback_pending" => [],
        "retired" => [ connection ]
      }.each do |state, expected|
        control.update!(state: state)
        scheduled = catalog.scheduling_scopes.flat_map(&:to_a) & [ item, connection ]
        assert_equal expected, scheduled, "unexpected scheduled owner for #{state}"
      end
    end
  end

  test "unmapped legacy items and native connections remain independently eligible" do
    with_provider_encryption do
      family = families(:dylan_family)
      item = family.up_items.create!(name: "Original Up", access_token: "private-up-token")
      native = create_provider_connection(family: family)
      gated = create_provider_connection(family: family, provider_key: "unavailable_adapter")
      disabled = create_provider_connection(family: family, status: "disabled")
      deleted = create_provider_connection(family: family, scheduled_for_deletion: true)
      foreign = create_provider_connection(family: families(:empty))
      scheduled = Family::ProviderSyncables.new(family).scheduling_scopes.flat_map(&:to_a)

      assert_includes scheduled, item
      assert_includes scheduled, native
      [ gated, disabled, deleted, foreign ].each { |record| assert_not_includes scheduled, record }
    end
  end

  test "family history includes both owners and paused connections but never another family" do
    with_provider_encryption do
      family = families(:dylan_family)
      item = family.up_items.create!(name: "Original Up", access_token: "private-up-token")
      connection = create_provider_connection(family: family, status: "disabled")
      ProviderMigrationControl.create!(family: family, provider_connection: connection,
        provider_key: "up", legacy_type: "UpItem", legacy_id: item.id, state: "rollback_pending")
      old_sync = item.syncs.create!(status: "completed")
      pending = connection.syncs.create!
      foreign = create_provider_connection(family: families(:empty)).syncs.create!

      history = Sync.for_family(family).where(id: [ old_sync.id, pending.id, foreign.id ])
      assert_equal [ old_sync.id, pending.id ].sort, history.ids.sort
      assert_includes Sync.for_family(family).incomplete, pending
    end
  end
end
