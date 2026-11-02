require "test_helper"

class SessionCleanerJobTest < ActiveSupport::TestCase
  test "deletes sessions inactive past the timeout and spares active ones" do
    user = users(:family_admin)

    stale = user.sessions.create!
    stale.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)

    fresh = user.sessions.create!

    SessionCleanerJob.perform_now

    assert_not Session.exists?(stale.id)
    assert Session.exists?(fresh.id)
  end
end
