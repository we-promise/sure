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
        invite_code = InviteCode.generate!
        post registration_url, params: { user: {
          email: "john@example.com",
          password: "Password1!",
          invite_code: invite_code } }
        assert_redirected_to root_url
        assert_not InviteCode.exists?(token: invite_code)
      end
    end
  end

  test "invite code is not consumed when signup fails validation" do
    with_env_overrides REQUIRE_INVITE_CODE: "true" do
      invite_code = InviteCode.generate!

      assert_no_difference "User.count" do
        post registration_url, params: { user: {
          email: "validationfail@example.com",
          password: "weak",
          invite_code: invite_code } }
      end

      assert_response :unprocessable_entity
      assert InviteCode.exists?(token: invite_code)
    end
  end

  test "invalid invite code does not create a user" do
    with_env_overrides REQUIRE_INVITE_CODE: "true" do
      assert_no_difference "User.count" do
        post registration_url, params: { user: {
          email: "valid@example.com",
          password: "Password1!",
          invite_code: "invalid-token-that-does-not-exist" } }
      end

      assert_redirected_to new_registration_url
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

  test "creating account from invitation shares existing family accounts when family shares by default" do
    invitation = invitations(:one)
    invitation.family.update!(default_account_sharing: "shared")

    post registration_url, params: { user: {
      email: invitation.email,
      password: "Password1!",
      invitation: invitation.token
    } }

    created_user = User.find_by(email: invitation.email)
    assert_not_nil created_user
    assert_equal invitation.family_id, created_user.family_id
    assert_equal invitation.family.accounts.pluck(:id).sort,
      AccountShare.where(user: created_user).pluck(:account_id).sort
  end

  test "creating account in invite-only default family shares existing family accounts" do
    family = families(:dylan_family)
    family.update!(default_account_sharing: "shared")
    Setting.onboarding_state = "invite_only"
    Setting.invite_only_default_family_id = family.id

    assert_difference "User.count", +1 do
      post registration_url, params: { user: {
        email: "default-family-signup@example.com",
        password: "Password1!"
      } }
    end

    created_user = User.find_by(email: "default-family-signup@example.com")
    assert_not_nil created_user
    assert_equal family.id, created_user.family_id
    assert_equal "member", created_user.role
    assert_equal family.accounts.pluck(:id).sort,
      AccountShare.where(user: created_user).pluck(:account_id).sort
    assert AccountShare.where(user: created_user).all?(&:read_write?)
  end

  test "creating account from invitation shares nothing when family sharing is private" do
    invitation = invitations(:one)
    invitation.family.update!(default_account_sharing: "private")

    post registration_url, params: { user: {
      email: invitation.email,
      password: "Password1!",
      invitation: invitation.token
    } }

    created_user = User.find_by(email: invitation.email)
    assert_not_nil created_user
    assert_equal 0, AccountShare.where(user: created_user).count
  end
end
