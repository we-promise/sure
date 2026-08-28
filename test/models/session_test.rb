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

    # `with_lock` reloads the row under a `SELECT ... FOR UPDATE`. Simulate a
    # concurrent request refreshing the session in that window: by the time
    # the lock is acquired and the block below runs, updated_at is no longer
    # stale, so the recheck inside `clean` must skip the destroy.
    original_with_lock = Session.instance_method(:with_lock)
    Session.define_method(:with_lock) do |&block|
      Session.where(id: id).update_all(updated_at: Time.current)
      reload
      block.call
    end

    deleted_count = Session.clean

    assert_equal 0, deleted_count
    assert Session.exists?(stale.id)
  ensure
    Session.define_method(:with_lock, original_with_lock)
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

  test "set_preferred_tab only persists allowlisted keys" do
    session = @user.sessions.create!

    session.set_preferred_tab("account_sidebar_tab", "asset")
    assert_equal "asset", session.get_preferred_tab("account_sidebar_tab")

    session.set_preferred_tab("some_arbitrary_key", "evil")
    assert_nil session.get_preferred_tab("some_arbitrary_key")
  end
end
