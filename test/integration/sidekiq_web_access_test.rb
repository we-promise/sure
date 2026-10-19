require "test_helper"

class SidekiqWebAccessTest < ActionDispatch::IntegrationTest
  test "logged-out visitor gets 404" do
    get "/sidekiq"

    assert_response :not_found
  end

  test "member gets 404" do
    sign_in users(:family_member)

    get "/sidekiq"

    assert_response :not_found
  end

  test "family admin gets 404" do
    sign_in users(:family_admin)

    get "/sidekiq"

    assert_response :not_found
  end

  test "super admin can access the dashboard" do
    sign_in users(:sure_support_staff)

    get "/sidekiq"

    assert_response :success
  end

  test "deactivated super admin gets 404 and the stale session is destroyed" do
    super_admin = users(:sure_support_staff)
    sign_in super_admin
    session_record = super_admin.sessions.order(created_at: :desc).first
    super_admin.update_column(:active, false)

    get "/sidekiq"

    assert_response :not_found
    assert_not Session.exists?(id: session_record.id), "stale session should be destroyed, not just denied"
  end

  test "garbage session cookie fails closed" do
    cookies[:session_token] = "not-a-signed-cookie"

    get "/sidekiq"

    assert_response :not_found
  end
end
