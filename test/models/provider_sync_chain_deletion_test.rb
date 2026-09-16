require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderSyncChainDeletionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "removing a connection destroys its successor chain and account children" do
    with_provider_encryption do
      connection = create_provider_connection
      original, successor, last = create_chain(connection)
      account_child = accounts(:depository).syncs.create!(parent: last)
      other_connection = create_provider_connection
      unrelated = other_connection.syncs.create!
      sync_ids = [ original.id, successor.id, last.id, account_child.id ]

      # Loading both associations reproduces two paths to the same successors.
      connection.syncs.load
      original.successors.load
      connection.destroy!

      assert_not ProviderConnection.exists?(connection.id)
      assert_empty Sync.where(id: sync_ids)
      assert Sync.exists?(unrelated.id)
      assert Account.exists?(account_child.syncable_id)
    end
  end

  test "removing a family sync destroys overlapping child and successor chains" do
    with_provider_encryption do
      connection = create_provider_connection
      family_sync = connection.family.syncs.create!
      original, successor, last = create_chain(connection, parent: family_sync)
      account_child = accounts(:depository).syncs.create!(parent: successor)
      unrelated = connection.syncs.create!
      sync_ids = [ family_sync.id, original.id, successor.id, last.id, account_child.id ]

      family_sync.children.load
      original.successors.load
      successor.successors.load
      family_sync.destroy!

      assert_empty Sync.where(id: sync_ids)
      assert Sync.exists?(unrelated.id)
      assert ProviderConnection.exists?(connection.id)
      assert Family.exists?(connection.family_id)
    end
  end

  test "captured predecessor evidence rolls back deletion of its successors" do
    with_provider_encryption do
      connection = create_provider_connection
      original, successor, last = create_chain(connection)
      batch = create_provider_batch(connection, sync: original)
      sync_ids = [ original.id, successor.id, last.id ]

      assert_retained_by_evidence(original, sync_ids)

      assert_equal original.id, batch.reload.sync_id
      assert_equal({ "records" => [] }, batch.payload)
      assert_equal original.id, successor.reload.predecessor_id
      assert_equal successor.id, last.reload.predecessor_id
    end
  end

  test "captured successor evidence prevents its connection from being removed" do
    with_provider_encryption do
      connection = create_provider_connection
      original, successor, last = create_chain(connection)
      batch = create_provider_batch(connection, sync: successor)

      assert_retained_by_evidence(connection, [ original.id, successor.id, last.id ])

      assert ProviderConnection.exists?(connection.id)
      assert_equal successor.id, batch.reload.sync_id
    end
  end

  test "an unfinished generation retains its family sync context without any pages" do
    with_provider_encryption do
      connection = create_provider_connection
      family_sync = connection.family.syncs.create!
      original, successor, last = create_chain(connection, parent: family_sync)
      generation = connection.provider_sync_generations.create!(sync: successor, writer_epoch: connection.writer_epoch)

      assert_retained_by_evidence(family_sync, [ family_sync.id, original.id, successor.id, last.id ])

      assert_equal successor.id, generation.reload.sync_id
      assert generation.fetching?
      assert_empty generation.ingestion_batches
      assert_equal family_sync.id, successor.reload.parent_id
    end
  end

  private
    def create_chain(connection, parent: nil)
      original = connection.syncs.create!(parent: parent)
      successor = connection.syncs.create!(parent: parent, predecessor: original)
      last = connection.syncs.create!(parent: parent, predecessor: successor)
      [ original, successor, last ]
    end

    def assert_retained_by_evidence(record, sync_ids)
      assert_raises(ActiveRecord::InvalidForeignKey) do
        # A savepoint keeps the fixture transaction usable after PostgreSQL
        # rejects deletion, and proves that earlier cascades roll back as well.
        Sync.transaction(requires_new: true) { record.destroy! }
      end
      assert_equal sync_ids.sort, Sync.where(id: sync_ids).pluck(:id).sort
    end
end
