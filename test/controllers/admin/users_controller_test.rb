require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:sure_support_staff)
  end

  test "index sorts users by subscription trial end date with nils last" do
    user_with_trial = User.find_by!(email: "user1@example.com")
    user_without_trial = User.find_by!(email: "bob@bobdylan.com")

    user_with_trial.family.subscription&.destroy
    Subscription.create!(
      family_id: user_with_trial.family_id,
      status: :trialing,
      trial_ends_at: 2.days.from_now
    )

    user_without_trial.family.subscription&.destroy
    Subscription.create!(
      family_id: user_without_trial.family_id,
      status: :active,
      trial_ends_at: nil,
      stripe_id: "cus_test_#{user_without_trial.family_id}"
    )

    get admin_users_url

    assert_response :success

    body = response.body
    trial_user_index = body.index("user1@example.com")
    no_trial_user_index = body.index("bob@bobdylan.com")

    assert_not_nil trial_user_index
    assert_not_nil no_trial_user_index
    assert_operator trial_user_index, :<, no_trial_user_index,
      "User with trialing subscription (user1@example.com) should appear before user with non-trial subscription (bob@bobdylan.com)"
  end

  test "index shows n/a when trial end date is unavailable" do
    get admin_users_url

    assert_response :success
    assert_match(/n\/a/, response.body, "Page should show n/a for users without trial end date")
  end
end
