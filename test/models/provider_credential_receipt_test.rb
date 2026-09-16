require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderCredentialReceiptTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  Receipt = ProviderCredentialReceipt
  StaleWriter = Provider::AccountData::StaleWriter

  test "first and following activity requests retain exact generation sync and preceding page ownership" do
    with_provider_encryption do
      generation = activity_generation
      first = build_receipt(generation)
      assert first.save!
      assert_nil first.preceding_batch_id
      page = capture_page(generation)
      following = build_receipt(generation, page_sequence: 1, from_revision: 1)

      assert following.save!
      assert_equal page.id, following.preceding_batch_id
      assert_equal generation.sync_id, following.sync_id
      assert_equal generation.provider_connection_id, following.provider_connection_id
      assert_equal generation.family_id, following.family_id
      refute_equal first.request_key, following.request_key
      assert_provider_column_encrypted(following, :evidence, '"prefix_fingerprint"')
    end
  end

  test "family and connection ownership cannot be changed through callback-free database insertion" do
    with_provider_encryption do
      generation = activity_generation
      foreign = create_provider_connection(family: families(:empty), provider_key: "trade_republic")
      [ { family_id: foreign.family_id }, { provider_connection_id: foreign.id, family_id: foreign.family_id } ].each do |changes|
        receipt = build_receipt(generation, **changes)

        assert_not receipt.valid?
        assert_insert_rejected(receipt, error_class: ActiveRecord::InvalidForeignKey)
      end
    end
  end

  test "another Sync on the same connection cannot own the original generation receipt" do
    with_provider_encryption do
      generation = activity_generation
      another_sync = generation.provider_connection.syncs.create!
      receipt = build_receipt(generation, sync_id: another_sync.id)

      assert_not receipt.valid?
      assert_insert_rejected(receipt, error_class: ActiveRecord::InvalidForeignKey)
    end
  end

  test "a receipt cannot use another connection Sync even with its original generation identifiers" do
    with_provider_encryption do
      generation = activity_generation
      foreign_sync = create_provider_connection.syncs.create!
      receipt = build_receipt(generation, sync_id: foreign_sync.id)

      assert_not receipt.valid?
      assert_insert_rejected(receipt, error_class: ActiveRecord::InvalidForeignKey)
    end
  end

  test "transaction generations cannot acquire activity credential receipts through database insertion" do
    with_provider_encryption do
      activity = activity_generation
      connection = activity.provider_connection
      transaction = connection.provider_sync_generations.create!(sync: connection.syncs.create!, stream: "transactions",
        writer_epoch: connection.writer_epoch, context_snapshot: {})
      receipt = build_receipt(activity, provider_sync_generation_id: transaction.id, sync_id: transaction.sync_id)

      assert_not receipt.valid?
      assert_insert_rejected(receipt)
      assert_raises(StaleWriter) do
        Receipt.scope_for(generation: transaction, page_sequence: 0, writer_epoch: connection.writer_epoch, lease_owner: connection.lease_owner)
      end
    end
  end

  test "page zero cannot claim a predecessor and later pages require the immediately preceding captured page" do
    with_provider_encryption do
      generation = activity_generation
      page = capture_page(generation)
      invalid = [
        build_receipt(generation, preceding_batch_id: page.id),
        build_receipt(generation, page_sequence: 1, preceding_batch_id: nil),
        build_receipt(generation, page_sequence: 1).tap { |receipt| receipt.page_sequence = 2 }
      ]

      invalid.each do |receipt|
        assert_not receipt.valid?
        assert receipt.errors[:preceding_batch].present?
        assert_insert_rejected(receipt)
      end
    end
  end

  test "an identically numbered page from a foreign generation cannot be a receipt predecessor" do
    with_provider_encryption do
      generation = activity_generation
      capture_page(generation)
      foreign = activity_generation(connection: create_provider_connection(family: families(:empty), provider_key: "trade_republic",
        writer_epoch: 1, lease_owner: SecureRandom.uuid, lease_expires_at: 5.minutes.from_now))
      foreign_page = capture_page(foreign)
      receipt = build_receipt(generation, page_sequence: 1, preceding_batch_id: foreign_page.id)

      assert_not receipt.valid?
      assert_insert_rejected(receipt)
    end
  end

  test "another generation on the same connection cannot lend its page to a request" do
    with_provider_encryption do
      first = activity_generation
      previous = capture_page(first)
      first.update!(status: "abandoned", error_code: "retained_test_prefix")
      current = activity_generation(connection: first.provider_connection)
      capture_page(current)
      receipt = build_receipt(current, page_sequence: 1, preceding_batch_id: previous.id)

      assert_not receipt.valid?
      assert_insert_rejected(receipt)
    end
  end

  test "ordinary batches and account children cannot stand in for captured activity pages" do
    with_provider_encryption do
      generation = activity_generation
      capture_page(generation)
      connection = generation.provider_connection
      ordinary = create_provider_batch(connection, sync: generation.sync)
      external = create_external_account(connection)
      child = create_provider_batch(connection, sync: generation.sync, provider_sync_generation: generation, generation_role: "account",
        stream: "activities", external_account: external, scope_key: "account:#{external.id}", sequence: 0, mode: "delta")

      [ ordinary, child ].each do |candidate|
        receipt = build_receipt(generation, page_sequence: 1, preceding_batch_id: candidate.id)
        assert_not receipt.valid?
        assert_insert_rejected(receipt)
      end
    end
  end

  test "only one positive-epoch ordinary session revision can be retained by each receipt" do
    with_provider_encryption do
      generation = activity_generation
      invalid = [
        { kind: "refresh" }, { provider_sync_type: "Account" },
        { from_revision: -1, to_revision: 0 }, { to_revision: 0 }, { to_revision: 2 },
        { writer_epoch: 0 }, { page_sequence: -1 }, { ordinal: -1 }, { ordinal: 64 }
      ]
      invalid.each do |changes|
        # Apply invalid sequence values after constructing the valid frame.
        receipt = build_receipt(generation).tap { |value| value.assign_attributes(changes) }
        assert_insert_rejected(receipt)
      end
    end
  end

  test "one connection revision and one attempt ordinal each have a unique receipt" do
    with_provider_encryption do
      generation = activity_generation
      original = build_receipt(generation).tap(&:save!)

      assert_insert_rejected(build_receipt(generation), error_class: ActiveRecord::RecordNotUnique)
      reused_attempt = build_receipt(generation, from_revision: 1, attempt_id: original.attempt_id, ordinal: original.ordinal)
      assert_insert_rejected(reused_attempt, error_class: ActiveRecord::RecordNotUnique)
    end
  end

  test "receipt updates including SQL no-op updates are immutable while normal destroy is refused" do
    with_provider_encryption do
      receipt = build_receipt(activity_generation).tap(&:save!)
      original = receipt.attributes.deep_dup

      assert_raises(StaleWriter) { receipt.update!(lease_owner: "another-lease") }
      assert_equal original, receipt.reload.attributes
      [ { lease_owner: "another-lease" }, { kind: "session" } ].each do |change|
        assert_raises(ActiveRecord::StatementInvalid) do
          ApplicationRecord.transaction(requires_new: true) { Receipt.where(id: receipt.id).update_all(change) }
        end
        assert_equal original, receipt.reload.attributes
      end
      assert_not receipt.destroy
      assert Receipt.exists?(receipt.id)
    end
  end

  test "receipt evidence accepts only bounded versioned fingerprints without plaintext credential fields" do
    with_provider_encryption do
      generation = activity_generation
      invalid = [ {}, { "version" => 1 },
        { "version" => 2, "prefix_fingerprint" => "a" * 64, "binding_fingerprint" => "b" * 64 },
        { "version" => 1, "prefix_fingerprint" => "not-a-fingerprint", "binding_fingerprint" => "b" * 64 },
        { "version" => 1, "prefix_fingerprint" => "a" * 64, "binding_fingerprint" => "b" * 64, "session_blob" => "private-cookie" } ]
      invalid.each do |evidence|
        receipt = build_receipt(generation, evidence: evidence)
        assert_not receipt.valid?
        assert receipt.errors[:evidence].present?
      end
    end
  end

  test "unchanged credential revisions recover without manufacturing a receipt" do
    with_provider_encryption do
      generation = activity_generation
      connection = generation.provider_connection
      snapshot = generation.context_snapshot.fetch("request_grant")

      assert_no_difference "Receipt.count" do
        assert_equal [], Receipt.recover!(connection: connection, generation: generation, page_sequence: 0,
          before: snapshot, after: snapshot, ids: [])
        scope = Receipt.scope_for(generation: generation, page_sequence: 0, writer_epoch: connection.writer_epoch, lease_owner: connection.lease_owner)
        connection.with_lock do
          admitted = Receipt.admit!(connection: connection, scope: scope, snapshot: snapshot)
          assert_equal [], admitted.fetch("recovered_receipt_ids")
          assert_raises(StaleWriter) do
            Receipt.record!(connection: connection, scope: admitted, before: snapshot, after: snapshot, ordinal: 0, kind: "session")
          end
        end
      end
    end
  end

  test "the issuer rejects refresh and grant changes even when the credential revision advanced" do
    with_provider_encryption do
      generation = activity_generation
      connection = generation.provider_connection
      before = generation.context_snapshot.fetch("request_grant")
      scope = Receipt.scope_for(generation: generation, page_sequence: 0, writer_epoch: connection.writer_epoch, lease_owner: connection.lease_owner)

      connection.with_lock do
        admitted = Receipt.admit!(connection: connection, scope: scope, snapshot: before)
        connection.update!(credentials: { "session_blob" => "rotated-private-cookie" })
        after = Provider::AccountData::RequestGrant.new(connection).capture!(scope_sync: generation.sync).snapshot
        assert_equal before.dig("connection", "credential_revision") + 1, after.dig("connection", "credential_revision")

        assert_no_difference "Receipt.count" do
          assert_raises(StaleWriter) { Receipt.record!(connection: connection, scope: admitted, before: before, after: after, ordinal: 0, kind: "refresh") }
          changed = after.deep_dup
          changed.fetch("connection")["provider_key"] = "another-provider"
          assert_raises(StaleWriter) { Receipt.record!(connection: connection, scope: admitted, before: before, after: changed, ordinal: 0, kind: "session") }
        end
      end
    end
  end

  private
    def activity_generation(connection: nil)
      connection ||= create_provider_connection(provider_key: "trade_republic", credentials: { "session_blob" => "private-cookie" },
        writer_epoch: 1, lease_owner: SecureRandom.uuid, lease_expires_at: 5.minutes.from_now)
      sync = connection.syncs.create!
      snapshot = Provider::AccountData::RequestGrant.new(connection).capture!(scope_sync: sync).snapshot
      connection.provider_sync_generations.create!(sync: sync, stream: "activities", writer_epoch: connection.writer_epoch,
        context_snapshot: { "request_grant" => snapshot, "accounts" => {} })
    end

    def capture_page(generation)
      sequence = generation.page_count
      page = create_provider_batch(generation.provider_connection, sync: generation.sync, provider_sync_generation: generation,
        generation_role: "page", stream: "activity_groups", sequence: sequence, mode: "delta", complete: false,
        payload: { "retained_response" => "private-page", "sequence" => sequence })
      generation.update!(page_count: sequence + 1)
      page
    end

    def build_receipt(generation, page_sequence: 0, from_revision: 0, **changes)
      frame = Receipt.scope_for(generation: generation, page_sequence: page_sequence,
        writer_epoch: generation.writer_epoch, lease_owner: generation.provider_connection.lease_owner)
      Receipt.new(frame.except("prefix_fingerprint").merge("attempt_id" => SecureRandom.uuid, "ordinal" => 0, "kind" => "session",
        "from_revision" => from_revision, "to_revision" => from_revision + 1,
        "evidence" => { "version" => 1, "prefix_fingerprint" => frame.fetch("prefix_fingerprint"), "binding_fingerprint" => "b" * 64 }).merge(changes.stringify_keys))
    end

    def assert_insert_rejected(receipt, error_class: ActiveRecord::StatementInvalid)
      attributes = receipt.attributes.except("id", "created_at", "updated_at")
        .merge("id" => SecureRandom.uuid, "created_at" => Time.current, "updated_at" => Time.current)
      assert_raises(error_class) do
        # insert_all! serializes encrypted attributes but runs no validations or
        # callbacks, exercising the database ownership and append-only guards.
        ApplicationRecord.transaction(requires_new: true) { Receipt.insert_all!([ attributes ], returning: false) }
      end
    end
end
