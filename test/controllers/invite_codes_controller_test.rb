require "test_helper"

class InviteCodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
  end
  test "super admin can generate invite codes" do
    sign_in users(:sure_support_staff)

    assert_difference("InviteCode.count") do
      post invite_codes_url, params: {}
    end
  end

  test "non-super-admin cannot generate invite codes" do
    sign_in users(:family_admin)

    assert_no_difference("InviteCode.count") do
      post invite_codes_url, params: {}
    end

    assert_redirected_to root_path
  end
end
