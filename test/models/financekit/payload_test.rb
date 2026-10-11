require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::PayloadTest < ActiveSupport::TestCase
  include FinancekitTestHelper

  setup { financekit_setup }

  test "posted_at is optional for every transaction status including booked" do
    Financekit::Payload::STATUSES.each do |status|
      payload = financekit_payload
      transaction = payload.fetch("events").last.fetch("transaction")
      transaction["status"] = status

      assert_same payload, Financekit::Payload.validate_batch!(payload, @item)
      transaction.delete("posted_at")
      assert_same payload, Financekit::Payload.validate_batch!(payload, @item)
    end
  end

  test "present posted_at must remain a valid nonfuture timestamp for every status" do
    Financekit::Payload::STATUSES.each do |status|
      [ nil, "", false, 123, "not-a-date", "2026-09-01T07:00:00", "2026-99-99T07:00:00Z", 1.minute.from_now.iso8601 ].each do |posted_at|
        payload = financekit_payload
        transaction = payload.fetch("events").last.fetch("transaction")
        transaction.merge!("status" => status, "posted_at" => posted_at)

        assert_no_difference "FinancekitBatch.count" do
          assert_raises(Financekit::Error, "#{status} with posted_at=#{posted_at.inspect}") { accept_batch(payload) }
        end
      end
    end
    assert_empty @source.account.entries
  end

  test "transacted_at remains required when posted_at is omitted" do
    payload = financekit_payload
    transaction = payload.fetch("events").last.fetch("transaction")
    transaction.delete("posted_at")
    transaction.delete("transacted_at")

    error = assert_raises(Financekit::Error) { accept_batch(payload) }
    assert_equal "invalid_payload", error.code
  end
end
