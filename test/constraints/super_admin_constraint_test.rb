require "test_helper"

class SuperAdminConstraintTest < ActionDispatch::IntegrationTest
  test "allows a super admin with an active session" do
    sign_in users(:sure_support_staff)

    get "/sidekiq"

    assert_response :success
  end

  test "rejects a super admin whose session is expired" do
    user = users(:sure_support_staff)
    sign_in user
    user.sessions.order(created_at: :desc).first.update_column(:updated_at, Session::INACTIVITY_TIMEOUT.ago - 1.day)

    get "/sidekiq"

    assert_response :not_found
  end

  test "rejects a non-super-admin with an active session" do
    sign_in users(:family_admin)

    get "/sidekiq"

    assert_response :not_found
  end

  test "rejects requests without a session cookie" do
    get "/sidekiq"

    assert_response :not_found
  end
end
