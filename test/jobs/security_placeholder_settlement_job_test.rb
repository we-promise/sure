require "test_helper"

class SecurityPlaceholderSettlementJobTest < ActiveJob::TestCase
  setup do
    @placeholder = Security.create!(ticker: "STLX", offline: true, offline_reason: "resolution_pending")
    @listed = Security.create!(ticker: "STLX", exchange_operating_mic: "XNAS")
  end

  test "merges a pending placeholder into the listed security" do
    SecurityPlaceholderSettlementJob.perform_now(@placeholder.id, @listed.id)

    assert_not Security.exists?(@placeholder.id)
  end

  test "skips a placeholder that was settled another way before the job ran" do
    @placeholder.update!(offline: false, offline_reason: nil)

    SecurityPlaceholderSettlementJob.perform_now(@placeholder.id, @listed.id)

    assert Security.exists?(@placeholder.id)
  end

  test "does nothing when either security is gone" do
    @placeholder.destroy!

    assert_nothing_raised { SecurityPlaceholderSettlementJob.perform_now(@placeholder.id, @listed.id) }
  end
end
