require "test_helper"

class Settings::AppearancesAccountOrderTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "appearance page offers the account order" do
    get settings_appearance_url

    assert_response :success
    assert_select "select[name='user[default_account_order]'] option[value='manual']"
  end

  test "updates the account order and keeps other preferences" do
    @user.update!(preferences: { "always_expanded_account_groups" => [ "depository" ] })

    patch settings_appearance_url, params: { user: { default_account_order: "manual" } }

    assert_redirected_to settings_appearance_url
    assert_equal "manual", @user.reload.default_account_order
    assert_equal [ "depository" ], @user.always_expanded_account_groups
  end

  test "ignores an unknown account order" do
    patch settings_appearance_url, params: { user: { default_account_order: "bogus" } }

    assert_redirected_to settings_appearance_url
    assert_equal "name_asc", @user.reload.default_account_order
  end
end
