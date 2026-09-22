require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::InboxTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  include ActiveJob::TestHelper

  setup { financekit_setup }

  test "capture chunks are accepted contiguously and applied atomically after final chunk" do
    capture_id = SecureRandom.uuid
    first_payload = financekit_payload(events: [])
    first_payload.merge!("capture_id" => capture_id, "chunk_index" => 0, "chunk_count" => 2)
    first, first_raw = accept_batch(first_payload)
    first_digest = Digest::SHA256.hexdigest(first_raw)

    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "accepted", first.reload.status

    second_payload = financekit_payload(sequence: 2, predecessor_digest: first_digest, events: [])
    second_payload.merge!("capture_id" => capture_id, "chunk_index" => 1, "chunk_count" => 2)
    second, = accept_batch(second_payload)
    FinancekitInboxJob.perform_now(@item.id)

    assert_equal "applied", first.reload.status
    assert_equal "applied", second.reload.status
    assert_equal 3, @item.reload.next_sequence
  end

  test "capture cannot begin at a later chunk" do
    payload = financekit_payload(events: [])
    payload.merge!("chunk_index" => 1, "chunk_count" => 2)

    error = assert_raises(Financekit::Error) { accept_batch(payload) }
    assert_equal "capture_conflict", error.code
  end

  test "repeated delivery returns the original receipt without another batch" do
    payload = financekit_payload
    original, raw = accept_batch(payload)
    accepted_receipt = original.receipt
    assert Financekit::Processor.new(@item).apply_next!

    assert_no_difference "FinancekitBatch.count" do
      repeated = FinancekitBatch.accept!(@item, raw, claimed_digest: original.payload_digest,
        idempotency_key: payload.fetch("batch_id"))
      assert_equal original.id, repeated.id
      assert_equal accepted_receipt.except(:status, :applied_at), repeated.receipt.except(:status, :applied_at)
      assert_equal "applied", repeated.receipt.fetch(:status)
    end
  end

  test "same batch ID or stream position with different bytes is rejected" do
    payload = financekit_payload
    original, = accept_batch(payload)
    payload["events"] = []

    error = assert_raises(Financekit::Error) { accept_batch(payload) }
    assert_equal "batch_conflict", error.code

    collision = financekit_payload
    error = assert_raises(Financekit::Error) { accept_batch(collision) }
    assert_equal "sequence_conflict", error.code
    assert_equal "accepted", original.reload.status
  end

  test "a permanent stream failure requires explicit repair and revokes following batches" do
    first, = accept_batch
    second_payload = financekit_payload(sequence: 2, predecessor_digest: "0" * 64, events: [])
    second, = accept_batch(second_payload)
    FinancekitInboxJob.perform_now(@item.id)

    assert_equal "applied", first.reload.status
    assert_equal "failed", second.reload.status
    assert_equal "predecessor_conflict", second.error_code
    assert_equal "repair_required", @item.reload.status
    assert_nil @item.credential_digest
  end

  test "unexpected processing errors are reported before retry" do
    batch, = accept_batch
    error = RuntimeError.new("financekit importer exploded")
    Financekit::Payload.stubs(:validate_batch!).raises(error)
    Rails.error.expects(:report).with(error, handled: true,
      context: { financekit_item_id: @item.id, batch_id: batch.batch_id })

    assert_not Financekit::Processor.new(@item).apply_next!

    assert_equal "accepted", batch.reload.status
    assert_equal "processing_error", batch.error_code
  end

  test "a record validation failure retries instead of fencing the publisher" do
    batch, = accept_batch
    Financekit::Payload.stubs(:validate_batch!).raises(ActiveRecord::RecordInvalid.new(Account.new))
    Rails.error.stubs(:report)

    assert_not Financekit::Processor.new(@item).apply_next!

    assert_equal "accepted", batch.reload.status
    assert_equal "import_validation", batch.error_code
    assert_equal 1, batch.attempts
    assert_not_nil batch.retry_at
    # The publisher keeps uploading: a background wake cannot reissue a
    # credential, so a single unlucky save must not clear it.
    assert_equal "active", @item.reload.status
    assert_not_nil @item.credential_digest
  end

  test "a persistent record validation failure still fences after the bounded attempts" do
    batch, = accept_batch
    Financekit::Payload.stubs(:validate_batch!).raises(ActiveRecord::RecordInvalid.new(Account.new))
    Rails.error.stubs(:report)

    Financekit::MAX_ATTEMPTS.times do
      batch.reload.update_columns(retry_at: nil)
      Financekit::Processor.new(@item).apply_next!
    end

    assert_equal "failed", batch.reload.status
    assert_equal "import_validation", batch.error_code
    assert_equal Financekit::MAX_ATTEMPTS, batch.attempts
    assert_equal "repair_required", @item.reload.status
    assert_nil @item.credential_digest
  end

  test "payload bytes are removed after the bounded replay window" do
    batch = accept_and_apply
    batch.update_columns(updated_at: 8.days.ago)

    FinancekitInboxJob.perform_now

    assert_nil batch.reload.payload
    assert_equal "applied", batch.status
    assert_not_nil batch.payload_digest
  end

  test "payload bytes from permanently failed batches are removed after the bounded replay window" do
    first, = accept_batch
    second, = accept_batch(financekit_payload(sequence: 2, predecessor_digest: "0" * 64, events: []))
    FinancekitInboxJob.perform_now(@item.id)
    second.update_columns(updated_at: 8.days.ago)

    FinancekitInboxJob.perform_now

    assert_equal "applied", first.reload.status
    assert_equal "failed", second.reload.status
    assert_nil second.payload
    assert_not_nil second.payload_digest
  end
  test "future transaction status remains source-only instead of failing the stream" do
    payload = financekit_payload
    transaction = payload.fetch("events").find { |event| event["kind"] == "transaction_upsert" }.fetch("transaction")
    transaction["status"] = "unknown"

    batch = accept_and_apply(payload)

    assert_equal "applied", batch.status
    assert_equal "active", @item.reload.status
    assert_empty @source.account.entries
    assert_equal "unknown", @source.financekit_transactions.find_by!(source_id: @transaction_id).status
  end
end
