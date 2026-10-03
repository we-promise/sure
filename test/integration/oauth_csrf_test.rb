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
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: user.id) # pipelock:ignore Credential in URL

    ActionController::Base.allow_forgery_protection = true
    delete oauth_authorized_application_path(application), params: {}

    assert_response :unprocessable_entity
    assert_not token.reload.revoked?
  end

  test "revoking an authorized application with a wrong CSRF token is rejected" do
    user = users(:family_admin)
    sign_in user

    application = Doorkeeper::Application.create!(
      name: "Test App", redirect_uri: "https://client.example.com/callback", scopes: "read"
    )
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: user.id) # pipelock:ignore Credential in URL

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
    token = Doorkeeper::AccessToken.create!(application: application, resource_owner_id: user.id) # pipelock:ignore Credential in URL

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
    delete oauth_application_path(application), params: {}

    assert_response :unprocessable_entity
    assert Doorkeeper::Application.exists?(application.id)
  end

  test "deleting a registered OAuth application with a wrong CSRF token is rejected" do
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

  test "deleting a registered OAuth application with a valid CSRF token succeeds" do
    super_admin = users(:sure_support_staff)
    sign_in super_admin

    application = Doorkeeper::Application.create!(
      name: "Malicious-looking App", redirect_uri: "https://attacker.example.com/callback", scopes: "read"
    )

    ActionController::Base.allow_forgery_protection = true
    # Loading a real page first is what seeds the session's CSRF token that
    # the subsequent delete request extracts and carries automatically.
    get oauth_applications_path
    assert_response :success
    csrf_token = css_select("meta[name=csrf-token]").first["content"]

    delete oauth_application_path(application), params: { authenticity_token: csrf_token }

    assert_redirected_to oauth_applications_url
    assert_not Doorkeeper::Application.exists?(application.id)
  end

  # These three tests hit POST /oauth/authorize directly — the consent-CSRF
  # endpoint the PR description calls out as "confirmed concretely
  # exploitable" via the plain form_tag in doorkeeper/authorizations/new.html.erb —
  # rather than relying on AuthorizedApplicationsController/ApplicationsController
  # coverage as a proxy for it. Doorkeeper's authorize params (client_id,
  # redirect_uri, response_type, scope) travel on the POST request itself, not
  # via a server-side session stash, so no separate seeding GET is required.
  test "authorizing an OAuth application without a CSRF token is rejected" do
    user = users(:family_admin)
    sign_in user

    application = Doorkeeper::Application.create!(
      name: "Test App", redirect_uri: "https://client.example.com/callback", scopes: "read"
    )

    ActionController::Base.allow_forgery_protection = true
    post oauth_authorization_path, params: {
      client_id: application.uid, redirect_uri: application.redirect_uri, response_type: "code", scope: "read"
    }

    assert_response :unprocessable_entity
    assert_equal 0, Doorkeeper::AccessGrant.where(application: application).count
  end

  test "authorizing an OAuth application with a wrong CSRF token is rejected" do
    user = users(:family_admin)
    sign_in user

    application = Doorkeeper::Application.create!(
      name: "Test App", redirect_uri: "https://client.example.com/callback", scopes: "read"
    )

    ActionController::Base.allow_forgery_protection = true
    post oauth_authorization_path, params: {
      client_id: application.uid, redirect_uri: application.redirect_uri, response_type: "code", scope: "read"
    }, headers: { "HTTP_X_CSRF_TOKEN" => "wrong-token" }

    assert_response :unprocessable_entity
    assert_equal 0, Doorkeeper::AccessGrant.where(application: application).count
  end

  test "authorizing an OAuth application with a valid CSRF token succeeds" do
    user = users(:family_admin)
    sign_in user

    application = Doorkeeper::Application.create!(
      name: "Test App", redirect_uri: "https://client.example.com/callback", scopes: "read"
    )

    ActionController::Base.allow_forgery_protection = true
    # Loading the consent page first is what seeds the session's CSRF token
    # that the subsequent authorize POST extracts and carries automatically.
    get oauth_authorization_path, params: {
      client_id: application.uid, redirect_uri: application.redirect_uri, response_type: "code", scope: "read"
    }
    assert_response :success
    csrf_token = css_select("meta[name=csrf-token]").first["content"]

    post oauth_authorization_path, params: {
      client_id: application.uid, redirect_uri: application.redirect_uri, response_type: "code", scope: "read",
      authenticity_token: csrf_token
    }

    assert_response :redirect
    assert_equal 1, Doorkeeper::AccessGrant.where(application: application).count
  end
end
