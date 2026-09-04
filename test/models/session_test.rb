require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
  end

  test "clean destroys sessions inactive past the timeout" do
    stale = @user.sessions.create!
    stale.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)

    fresh = @user.sessions.create!

    deleted_count = Session.clean

    assert_equal 1, deleted_count
    assert_not Session.exists?(stale.id)
    assert Session.exists?(fresh.id)
  end

  test "expired? is true once past the inactivity timeout" do
    session = @user.sessions.create!
    assert_not session.expired?

    session.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)
    assert session.expired?
  end

  test "clean spares a session touched between the stale query and the row lock" do
    stale = @user.sessions.create!
    stale.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)

    # Simulate a concurrent request refreshing the session between the initial
    # stale-session query and the row lock inside `clean`: stub `updated_at`
    # so the recheck sees a fresh timestamp, while leaving the real
    # `with_lock` (and its `SELECT ... FOR UPDATE` reload) in place so the
    # locked recheck path is actually exercised.
    Session.any_instance.stubs(:updated_at).returns(Time.current)

    deleted_count = Session.clean

    assert_equal 0, deleted_count
    assert Session.exists?(stale.id)
  end

  test "clean rescues a session destroyed between the stale query and the row lock" do
    stale = @user.sessions.create!
    stale.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)

    # Simulate find_active_by_cookie destroying this session concurrently:
    # with_lock reloads the row before yielding, so a destroy in that window
    # surfaces as RecordNotFound instead of running the block. `clean` must
    # rescue this and move on rather than aborting the sweep.
    Session.any_instance.stubs(:with_lock).raises(ActiveRecord::RecordNotFound)

    deleted_count = Session.clean

    assert_equal 0, deleted_count
  end

  test "find_active_by_cookie returns nil for a blank cookie" do
    assert_nil Session.find_active_by_cookie(nil)
    assert_nil Session.find_active_by_cookie("")
  end

  test "find_active_by_cookie returns nil and cleans up an unknown session id" do
    assert_nil Session.find_active_by_cookie(SecureRandom.uuid)
  end

  test "find_active_by_cookie returns the session when active" do
    session = @user.sessions.create!
    assert_equal session, Session.find_active_by_cookie(session.id)
  end

  test "find_active_by_cookie destroys and returns nil for an expired session" do
    session = @user.sessions.create!
    session.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)

    assert_nil Session.find_active_by_cookie(session.id)
    assert_not Session.exists?(session.id)
  end

  test "find_active_by_cookie destroys and returns nil when the user is inactive" do
    session = @user.sessions.create!
    User.any_instance.stubs(:active?).returns(false)

    assert_nil Session.find_active_by_cookie(session.id)
    assert_not Session.exists?(session.id)
  end

  test "find_active_by_cookie refreshes updated_at once past the touch interval" do
    session = @user.sessions.create!
    session.update_column(:updated_at, Session::SESSION_TOUCH_INTERVAL.ago - 1.minute)

    Session.find_active_by_cookie(session.id)

    assert session.reload.updated_at > Session::SESSION_TOUCH_INTERVAL.ago
  end

  test "find_active_by_cookie does not touch a recently active session" do
    session = @user.sessions.create!
    recent_updated_at = Session::SESSION_TOUCH_INTERVAL.ago + 1.minute
    session.update_column(:updated_at, recent_updated_at)

    Session.find_active_by_cookie(session.id)

    assert_in_delta recent_updated_at, session.reload.updated_at, 1.second
  end

  test "set_preferred_tab only persists allowlisted keys" do
    session = @user.sessions.create!

    session.set_preferred_tab("account_sidebar_tab", "asset")
    assert_equal "asset", session.get_preferred_tab("account_sidebar_tab")

    session.set_preferred_tab("some_arbitrary_key", "evil")
    assert_nil session.get_preferred_tab("some_arbitrary_key")
  end
end
