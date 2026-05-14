require "test_helper"

class SweepExpiredGoalPledgesJobTest < ActiveJob::TestCase
  test "marks open pledges past expires_at as expired" do
    pledge = goal_pledges(:open_transfer)
    pledge.update_columns(expires_at: 1.day.ago)

    SweepExpiredGoalPledgesJob.perform_now

    assert pledge.reload.status_expired?
  end

  test "leaves open pledges still inside window alone" do
    pledge = goal_pledges(:open_transfer)
    assert pledge.expires_at > Time.current

    SweepExpiredGoalPledgesJob.perform_now

    assert pledge.reload.status_open?
  end

  test "ignores already-matched or cancelled pledges" do
    matched = goal_pledges(:matched_transfer)
    expired = goal_pledges(:expired_transfer)

    SweepExpiredGoalPledgesJob.perform_now

    assert matched.reload.status_matched?
    assert expired.reload.status_expired?
  end
end
