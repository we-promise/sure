require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:sure_support_staff)
  end

  test "index sorts users by subscription trial end date with nils last" do
    get admin_users_url

    assert_response :success

    body = response.body
    trial_user_index = body.index("user1@example.com")
    no_trial_user_index = body.index("bob@bobdylan.com")

    assert_not_nil trial_user_index
    assert_not_nil no_trial_user_index
    assert_operator trial_user_index, :<, no_trial_user_index
  end

  test "index shows n/a when trial end date is unavailable" do
    get admin_users_url

    assert_response :success
    assert_match(/n\/a/, response.body, "Page should show n/a for users without trial end date")
  end
end
