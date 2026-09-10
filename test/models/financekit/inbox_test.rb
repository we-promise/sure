require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::InboxTest < ActiveSupport::TestCase
  include FinancekitTestHelper

  setup { financekit_setup }

  test "replaying enrollment is idempotent but changed key conflicts" do
    assert_equal @item, Financekit::Enrollment.create!(@user, @enrollment)
    changed = @enrollment.deep_dup
    changed["consent"]["source_ids"] << SecureRandom.uuid
    assert_equal 409, assert_raises(Financekit::Error) { Financekit::Enrollment.create!(@user, changed) }.status
  end

  test "acceptance is durable without enqueue and replay preserves one receipt" do
    FinancekitInboxJob.expects(:perform_later).never
    envelope = financekit_envelope
    batch = FinancekitBatch.accept!(@item, envelope)
    assert_equal "accepted", batch.status
    assert_no_difference "FinancekitBatch.count" do
      assert_equal batch, FinancekitBatch.accept!(@item, envelope)
    end
    assert_nil @item.reload.last_imported_at
    assert_not_nil @item.last_accepted_at
    assert Financekit::Processor.new(@item).apply_next!
    assert_equal "applied", batch.reload.status
    assert_equal BigDecimal("12.34"), @source.account.entries.sole.amount
  end

  test "out of order batches wait and apply contiguously" do
    first_envelope = financekit_envelope
    claims = JWT.decode(first_envelope, nil, false).first
    second = FinancekitBatch.accept!(@item, financekit_envelope(sequence: 2, previous: claims["digest"]))
    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "accepted", second.reload.status
    FinancekitBatch.accept!(@item, first_envelope)
    2.times { assert Financekit::Processor.new(@item).apply_next! }
    assert_equal 1, @source.account.entries.count
    assert_equal 3, @item.reload.next_sequence
  end

  test "same batch or sequence with different immutable content conflicts" do
    batch = FinancekitBatch.accept!(@item, financekit_envelope)
    assert_equal 409, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, financekit_envelope(batch_id: batch.batch_id)) }.status
    assert_equal 409, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, financekit_envelope) }.status
  end

  test "whole malformed batch is rejected without accepting valid records" do
    data = financekit_payload
    data["transactions"] << data["transactions"].first.merge("source_id" => SecureRandom.uuid, "amount" => 12.34)
    assert_no_difference "FinancekitBatch.count" do
      assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, financekit_envelope(data)) }
    end
  end

  test "processor rolls back ledger and acknowledgment together" do
    batch = FinancekitBatch.accept!(@item, financekit_envelope)
    @item.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(@item))
    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "failed", batch.reload.status
    assert_equal 0, @source.account.entries.count
    assert_equal 1, @item.reload.next_sequence
  end

  test "bad predecessor fails explicitly and never skips stream" do
    FinancekitBatch.accept!(@item, financekit_envelope)
    assert Financekit::Processor.new(@item).apply_next!
    bad = FinancekitBatch.accept!(@item, financekit_envelope(sequence: 2, previous: "0" * 64))
    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "failed", bad.reload.status
    assert_equal "predecessor_conflict", bad.error_code
    assert_equal 2, @item.reload.next_sequence
  end

  test "replacement fences queued old generation and keeps source identity" do
    envelope = financekit_envelope
    batch = FinancekitBatch.accept!(@item, envelope)
    @item.replace_device!({ "expected_generation" => 1, "device_public_key" => @device_jwk,
      "consent" => @enrollment["consent"], "continuity" => "same_source_and_transaction_ids" })
    assert_equal "revoked", batch.reload.status
    assert_equal @source.id, @item.financekit_accounts.sole.id
    assert_equal 409, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, envelope) }.status
    assert_equal 0, @source.account.entries.count
  end

  test "disconnect preserves ledger and rejects queued and future imports" do
    FinancekitBatch.accept!(@item, financekit_envelope)
    Financekit::Processor.new(@item).apply_next!
    @item.disconnect!
    assert_equal 1, @source.account.entries.count
    assert_equal 403, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, financekit_envelope) }.status
  end

  test "old receipt remains deduplicated after encrypted payload is pruned" do
    envelope = financekit_envelope
    batch = FinancekitBatch.accept!(@item, envelope)
    Financekit::Processor.new(@item).apply_next!
    batch.update!(envelope: nil)
    assert_equal batch.id, FinancekitBatch.accept!(@item, envelope).id
    assert_equal 1, @source.account.entries.count
  end

  test "another family source or stale mapping cannot be uploaded" do
    data = financekit_payload
    data["transactions"].first["account_id"] = SecureRandom.uuid
    assert_equal 409, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, financekit_envelope(data)) }.status
    data = financekit_payload
    data["accounts"].first["mapping_version"] = 2
    assert_equal 409, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, financekit_envelope(data)) }.status
  end

  test "deactivated publisher cannot import already accepted data" do
    batch = FinancekitBatch.accept!(@item, financekit_envelope)
    @item.user.stubs(:active?).returns(false)
    assert_not Financekit::Processor.new(@item).apply_next!
    assert_equal "accepted", batch.reload.status
    assert_equal 0, @source.account.entries.count
  end
end
