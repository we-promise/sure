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

  test "set_preferred_tab only persists allowlisted keys" do
    session = @user.sessions.create!

    session.set_preferred_tab("account_sidebar_tab", "asset")
    assert_equal "asset", session.get_preferred_tab("account_sidebar_tab")

    session.set_preferred_tab("some_arbitrary_key", "evil")
    assert_nil session.get_preferred_tab("some_arbitrary_key")
  end
end
