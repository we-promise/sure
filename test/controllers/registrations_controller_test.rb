require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "new" do
    get new_registration_url
    assert_response :success
  end

  test "create redirects to correct URL" do
    post registration_url, params: { user: {
      email: "john@example.com",
      password: "Password1!" } }

    assert_redirected_to root_url
  end

  test "first user of instance becomes super_admin" do
    # Clear all users to simulate fresh instance
    User.destroy_all

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: "firstuser@example.com",
        password: "Password1!" } }
    end

    first_user = User.find_by(email: "firstuser@example.com")
    assert first_user.super_admin?, "First user should be super_admin"
  end

  test "subsequent users become admin not super_admin" do
    # Ensure users exist from fixtures
    assert User.exists?

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: "seconduser@example.com",
        password: "Password1!" } }
    end

    new_user = User.find_by(email: "seconduser@example.com")
    assert new_user.admin?, "Subsequent user should be admin"
    assert_not new_user.super_admin?, "Subsequent user should not be super_admin"
  end

  test "create when hosted requires an invite code" do
    with_env_overrides REQUIRE_INVITE_CODE: "true" do
      assert_no_difference "User.count" do
        post registration_url, params: { user: {
          email: "john@example.com",
          password: "Password1!" } }
        assert_redirected_to new_registration_url

        post registration_url, params: { user: {
          email: "john@example.com",
          password: "Password1!",
          invite_code: "foo" } }
        assert_redirected_to new_registration_url
      end

      assert_difference "User.count", +1 do
        post registration_url, params: { user: {
          email: "john@example.com",
          password: "Password1!",
          invite_code: InviteCode.generate! } }
        assert_redirected_to root_url
      end
    end
  end

  test "creating account from guest invitation assigns guest role and intro layout" do
    invitation = invitations(:one)
    invitation.update!(role: "guest", email: "guest-signup@example.com")

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: invitation.email,
        password: "Password1!",
        invitation: invitation.token
      } }
    end

    created_user = User.find_by(email: invitation.email)
    assert_equal "guest", created_user.role
    assert created_user.ui_layout_intro?
    assert_not created_user.show_sidebar?
    assert_not created_user.show_ai_sidebar?
    assert created_user.ai_enabled?
  end
end
