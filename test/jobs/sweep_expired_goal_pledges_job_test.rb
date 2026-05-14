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

  test "ignores already-matched, cancelled, or already-expired pledges" do
    matched = goal_pledges(:matched_transfer)
    expired = goal_pledges(:expired_transfer)
    # Build the cancelled pledge inline rather than baking it into fixtures
    # so the cancelled-path coverage stays test-local.
    cancelled = matched.goal.goal_pledges.create!(
      account: matched.account,
      amount: 25,
      currency: matched.currency,
      kind: matched.kind,
      status: "cancelled",
      expires_at: 2.days.ago
    )

    SweepExpiredGoalPledgesJob.perform_now

    assert matched.reload.status_matched?
    assert expired.reload.status_expired?
    assert cancelled.reload.status_cancelled?
  end

  test "logs and continues when a single pledge fails to expire" do
    pledge = goal_pledges(:open_transfer)
    pledge.update_columns(expires_at: 1.day.ago)
    GoalPledge.any_instance.stubs(:expire!).raises(StandardError, "boom")

    assert_nothing_raised { SweepExpiredGoalPledgesJob.perform_now }
  end
end
