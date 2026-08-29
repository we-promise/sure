require "test_helper"

# CSRF protection is globally disabled in the test environment
# (config.action_controller.allow_forgery_protection = false in
# config/environments/test.rb), so these tests toggle it on for their
# duration — otherwise a regression of the doorkeeper_csrf_protection.rb
# removal (accidentally reintroducing a blanket skip_forgery_protection)
# would pass the full suite silently.
#
# Sign-in happens BEFORE toggling protection on: SessionsController#create
# isn't a Doorkeeper controller and the sign_in test helper doesn't carry a
# token either, so flipping protection on first would make sign_in itself
# get rejected — every request after that would 302 to the login page
# regardless of whether the Doorkeeper CSRF check being tested actually
# fired, turning "rejected" assertions into false positives for the wrong
# reason.
class OauthCsrfTest < ActionDispatch::IntegrationTest
  teardown do
    ActionController::Base.allow_forgery_protection = false
  end

  test "revoking an authorized application without a CSRF token is rejected" do
    user = users(:family_admin)
    sign_in user

    application = Doorkeeper::Application.create!(
      name: "Test App", redirect_uri: "https://client.example.com/callback", scopes: "read"
    )
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: user.id)

    ActionController::Base.allow_forgery_protection = true
    delete oauth_authorized_application_path(application), params: {}, headers: { "HTTP_X_CSRF_TOKEN" => "wrong-token" }

    assert_response :unprocessable_entity
    assert_not token.reload.revoked?
  end

  test "revoking an authorized application with a valid CSRF token succeeds" do
    user = users(:family_admin)
    sign_in user

    application = Doorkeeper::Application.create!(
      name: "Test App", redirect_uri: "https://client.example.com/callback", scopes: "read"
    )
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: user.id)

    ActionController::Base.allow_forgery_protection = true
    # Loading a real page first is what seeds the session's CSRF token that
    # the subsequent delete request extracts and carries automatically.
    get oauth_authorized_applications_path
    assert_response :success
    csrf_token = css_select("meta[name=csrf-token]").first["content"]

    delete oauth_authorized_application_path(application), params: { authenticity_token: csrf_token }

    assert_redirected_to oauth_authorized_applications_url
    assert token.reload.revoked?
  end

  test "deleting a registered OAuth application without a CSRF token is rejected" do
    super_admin = users(:sure_support_staff)
    sign_in super_admin

    application = Doorkeeper::Application.create!(
      name: "Malicious-looking App", redirect_uri: "https://attacker.example.com/callback", scopes: "read"
    )

    ActionController::Base.allow_forgery_protection = true
    delete oauth_application_path(application), params: {}, headers: { "HTTP_X_CSRF_TOKEN" => "wrong-token" }

    assert_response :unprocessable_entity
    assert Doorkeeper::Application.exists?(application.id)
  end
end
