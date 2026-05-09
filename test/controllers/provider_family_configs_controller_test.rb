require "test_helper"

class ProviderFamilyConfigsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "create saves config and redirects to settings/providers" do
    # Remove the existing truelayer config so we can create a fresh one
    provider_family_configs(:truelayer_family_one).destroy

    assert_difference "Provider::FamilyConfig.count" do
      post provider_family_configs_path, params: {
        provider_family_config: {
          provider_key: "truelayer",
          client_id: "my_client_id",
          client_secret: "my_secret"
        }
      }
    end
    assert_redirected_to settings_providers_path
    config = Provider::FamilyConfig.order(created_at: :desc).first
    assert_equal "my_client_id", config.client_id
  end

  test "destroy removes config and redirects" do
    config = provider_family_configs(:truelayer_family_one)
    assert_difference "Provider::FamilyConfig.count", -1 do
      delete provider_family_config_path(config)
    end
    assert_redirected_to settings_providers_path
  end
end
