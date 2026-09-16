require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::LegacySyncScopeTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  test "sync context requires admission and returns the current persisted owner" do
    with_item do |item|
      sync = item.syncs.create!
      assert_raises(Fence::InvalidSource) { Fence.scoped_sync!(item, sync) }

      Fence.with_item(item) do |current|
        assert_nil Fence.scoped_sync!(current, nil)
        fresh_sync = Fence.scoped_sync!(current, sync)
        assert_equal sync.id, fresh_sync.id
        assert_not_same sync, fresh_sync
        assert_raises(Fence::InvalidSource) { Fence.scoped_sync!(item, sync) }
        assert_raises(Fence::InvalidSource) { Fence.scoped_sync!(current, item.syncs.build) }
      end
    end
  end

  test "foreign deleted failed stale and cancelled contexts are rejected before delayed work" do
    with_item do |item|
      sync = item.syncs.create!
      foreign = item.family.syncs.create!
      Fence.with_item(item) do |current|
        assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current, foreign) }
        %w[failed stale].each do |status|
          sync.update_columns(status: status)
          assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current, sync, allow_completed: true) }
        end
        sync.update_columns(status: "syncing", cancel_requested_at: Time.current)
        assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current, sync, allow_completed: true) }
        Sync.where(id: sync.id).delete_all
        assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current, sync) }
      end
    ensure
      foreign&.destroy!
    end
  end

  test "completed parents require the explicit legacy delayed-work policy" do
    with_item do |item|
      parent = item.family.syncs.create!(status: "completed")
      sync = item.syncs.create!(status: "completed", parent: parent)
      Fence.with_item(item) do |current|
        assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current, sync) }
        assert_equal sync.id, Fence.scoped_sync!(current, sync, allow_completed: true).id
        parent.update_columns(cancel_requested_at: Time.current)
        assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current, sync, allow_completed: true) }
      end
    ensure
      parent&.destroy!
    end
  end

  test "ancestry cycles fail without looping" do
    with_item do |item|
      sync = item.syncs.create!
      sync.update_columns(parent_id: sync.id)
      Fence.with_item(item) do |current|
        assert_raises(Fence::OwnershipChanged) { Fence.scoped_sync!(current, sync) }
      end
    ensure
      sync&.update_columns(parent_id: nil)
    end
  end

  private
    def with_item
      with_provider_encryption do
        item = SophtronItem.create!(family: families(:dylan_family), name: "Legacy sync context",
          user_id: "test-user", access_key: Base64.strict_encode64("test-key"))
        begin
          yield item
        ensure
          item.reload.destroy!
        end
      end
    end
end
