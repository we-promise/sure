require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::InboxTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  include ActiveJob::TestHelper

  setup { financekit_setup }

  test "out of order batches remain durable and apply in sequence when the gap arrives" do
    first_payload = financekit_payload
    first_raw = JSON.generate(first_payload)
    first_digest = Digest::SHA256.hexdigest(first_raw)
    second_payload = financekit_payload(sequence: 2, predecessor_digest: first_digest, events: [])
    second, = accept_batch(second_payload)

    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "accepted", second.reload.status

    first = FinancekitBatch.accept!(@item, first_raw, claimed_digest: first_digest,
      idempotency_key: first_payload.fetch("batch_id"))
    FinancekitInboxJob.perform_now(@item.id)

    assert_equal "applied", first.reload.status
    assert_equal "applied", second.reload.status
    assert_equal 3, @item.reload.next_sequence
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
      assert_equal accepted_receipt, repeated.receipt
      assert_equal "accepted", repeated.receipt.fetch(:status)
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
end
