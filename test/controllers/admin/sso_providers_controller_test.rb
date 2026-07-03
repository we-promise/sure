require "test_helper"

class Admin::SsoProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:sure_support_staff)

    @provider = SsoProvider.create!(
      strategy: "google_oauth2",
      name: "google_oauth2_test",
      label: "Sign in with Google",
      enabled: true,
      client_id: "client-id",
      client_secret: "existing-secret",
      settings: { "default_role" => "member" }
    )
  end

  test "edit form posts nested settings and optional client secret" do
    get edit_admin_sso_provider_path(@provider)

    assert_response :success
    assert_includes response.body, 'name="sso_provider[settings][default_role]"'
    assert_includes response.body, 'name="sso_provider[settings][scopes]"'
    assert_includes response.body, 'name="sso_provider[settings][prompt]"'
    assert_includes response.body, 'name="sso_provider[client_secret]"'
    assert_no_match(/name="sso_provider\[client_secret\]"[^>]*required/, response.body)
  end

  test "update persists nested default role setting" do
    patch admin_sso_provider_path(@provider), params: {
      sso_provider: valid_update_params(settings: { default_role: "guest" })
    }

    assert_redirected_to admin_sso_providers_path
    assert_equal "guest", @provider.reload.settings["default_role"]
  end

  test "update preserves existing client secret when blank" do
    patch admin_sso_provider_path(@provider), params: {
      sso_provider: valid_update_params(client_secret: "", label: "Updated Google")
    }

    assert_redirected_to admin_sso_providers_path
    @provider.reload
    assert_equal "Updated Google", @provider.label
    assert_equal "existing-secret", @provider.client_secret
  end

  private
    def valid_update_params(overrides = {})
      {
        strategy: @provider.strategy,
        name: @provider.name,
        label: @provider.label,
        enabled: "1",
        client_id: @provider.client_id,
        client_secret: @provider.client_secret,
        settings: @provider.settings
      }.deep_merge(overrides)
    end
end
