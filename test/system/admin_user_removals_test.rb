require "application_system_test_case"

class AdminUserRemovalsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @admin = users(:sure_support_staff)
    @target = users(:family_member)
    @target_email = @target.email
    @identity = @target.oidc_identities.first!
    @provider = @identity.provider
    @uid = @identity.uid
  end

  test "super admin confirms removal and the SSO identity cannot return" do
    sign_in @admin
    visit admin_users_path

    find("details", text: @target.family.name).find("summary").click

    within find("tr", text: @target_email) do
      find("button[aria-haspopup='dialog']").click
    end
    click_on "Delete User"

    within "dialog[open]" do
      assert_text "This immediately revokes access"
      fill_in "User email", with: @target_email
      click_on "Permanently remove user"
    end

    assert_text "User access revoked and permanent deletion scheduled."
    assert_not @target.reload.active?
    assert_empty @target.sessions
    assert_empty @target.oidc_identities
    assert SsoIdentityBlock.blocked?(provider: @provider, uid: @uid)

    OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new(
      provider: @provider,
      uid: @uid,
      info: { email: @target_email, name: "Removed SSO User" }
    )

    visit "/auth/openid_connect/callback"

    assert_current_path new_session_path
    assert_text "Could not authenticate via OpenID Connect."
    assert_not User.exists?(email: @target_email)
  ensure
    OmniAuth.config.mock_auth[:openid_connect] = nil
  end
end
