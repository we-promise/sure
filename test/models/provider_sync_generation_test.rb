require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderSyncGenerationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "only one unfinished generation may own a connection stream" do
    with_provider_encryption do
      connection = create_provider_connection
      first = generation(connection)
      second = connection.provider_sync_generations.build(sync: connection.syncs.create!, writer_epoch: 0)
      assert_database_rejects(second, error_class: ActiveRecord::RecordNotUnique)
      first.update!(status: "abandoned", error_code: "interrupted_fetch")
      assert second.save!
    end
  end

  test "generation ownership requires the same family and connection sync in the database" do
    with_provider_encryption do
      connection = create_provider_connection
      other = create_provider_connection(family: families(:empty))
      foreign = connection.provider_sync_generations.build(family: other.family, sync: connection.syncs.create!, writer_epoch: 0)
      assert_not foreign.valid?
      assert_database_rejects(foreign)
      foreign.assign_attributes(family: connection.family, sync: other.syncs.create!)
      assert_not foreign.valid?
      assert_database_rejects(foreign)
    end
  end

  test "captured scope and binding evidence cannot change or reopen after abandonment" do
    with_provider_encryption do
      connection = create_provider_connection
      captured = generation(connection, start_cursor: "private-cursor")
      captured.update!(status: "abandoned", error_code: "interrupted_fetch")
      captured.assign_attributes(status: "fetching", start_cursor: "replacement", context_snapshot: { "accounts" => {} })
      assert_not captured.valid?
      assert captured.errors[:status].present?
      assert captured.errors[:start_cursor].present?
      assert captured.errors[:context_snapshot].present?
      assert_provider_column_encrypted(captured.reload, :start_cursor, "private-cursor")
    end
  end

  test "a checkpoint cannot reference a provisional generation" do
    with_provider_encryption do
      connection = create_provider_connection
      captured = generation(connection)
      cursor = connection.provider_sync_checkpoints.build(stream: "transactions", scope_key: "connection", provider_sync_generation: captured)
      assert_not cursor.valid?
      assert cursor.errors[:provider_sync_generation].present?
    end
  end

  test "generation batches cannot be attached across connections or without an explicit role" do
    with_provider_encryption do
      connection = create_provider_connection
      other = create_provider_connection
      captured = generation(connection)
      batch = other.ingestion_batches.build(sync: other.syncs.create!, origin_kind: "provider", writer_epoch: 0,
        stream: "transaction_groups", scope_key: "connection", mode: "delta", complete: false,
        provider_sync_generation: captured, generation_role: "page", idempotency_key: SecureRandom.uuid)
      assert_not batch.valid?
      assert_database_rejects(batch)
      batch.assign_attributes(provider_connection: connection, family: connection.family, sync: captured.sync, generation_role: nil)
      assert_not batch.valid?
      assert_database_rejects(batch, error_class: ActiveRecord::StatementInvalid)
    end
  end

  test "a group checkpoint cannot be rebound to an account scope through direct database writes" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      captured = generation(connection)
      cursor = connection.provider_sync_checkpoints.build(stream: "transactions", scope_key: "account:#{external.id}",
        external_account: external, provider_sync_generation: captured)
      assert_not cursor.valid?
      assert_database_rejects(cursor, error_class: ActiveRecord::StatementInvalid)
    end
  end

  test "generation batch sync and writer epoch are enforced by the database" do
    with_provider_encryption do
      connection = create_provider_connection
      captured = generation(connection)
      batch = connection.ingestion_batches.build(family: connection.family, sync: connection.syncs.create!, origin_kind: "provider", writer_epoch: 0,
        stream: "transaction_groups", scope_key: "connection", mode: "delta", complete: false,
        provider_sync_generation: captured, generation_role: "page", idempotency_key: SecureRandom.uuid)
      assert_not batch.valid?
      assert_database_rejects(batch)
      batch.assign_attributes(sync: captured.sync, writer_epoch: captured.writer_epoch + 1)
      assert_not batch.valid?
      assert_database_rejects(batch)
    end
  end

  test "connection generations cannot acquire a singular authorization on an evidence batch" do
    with_provider_encryption do
      connection = create_provider_connection
      captured = generation(connection)
      authorization = connection.provider_authorizations.create!(status: "active")
      batch = connection.ingestion_batches.build(family: connection.family, sync: captured.sync, origin_kind: "provider", writer_epoch: captured.writer_epoch,
        stream: "transaction_groups", scope_key: "connection", mode: "delta", complete: false,
        provider_sync_generation: captured, provider_authorization: authorization, generation_role: "page", idempotency_key: SecureRandom.uuid)
      assert_not batch.valid?
      assert_database_rejects(batch, error_class: ActiveRecord::StatementInvalid)
    end
  end

  private
    def generation(connection, **attributes)
      connection.provider_sync_generations.create!({ sync: connection.syncs.create!, writer_epoch: connection.writer_epoch,
        context_snapshot: { "version" => 1, "accounts" => {}, "checkpoint" => { "id" => nil, "lock_version" => nil } } }.merge(attributes))
    end
end
