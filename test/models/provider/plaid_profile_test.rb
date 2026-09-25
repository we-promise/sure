require "test_helper"

class Provider::PlaidProfileTest < ActiveSupport::TestCase
  test "loads additional profiles from environment variables" do
    with_env_overrides(
      PLAID_PROFILE_SECONDARY_CLIENT_ID: "secondary-client",
      PLAID_PROFILE_SECONDARY_SECRET: "secondary-secret",
      PLAID_PROFILE_SECONDARY_ENV: "production",
      PLAID_PROFILE_SECONDARY_REGION: "us",
      PLAID_PROFILE_SECONDARY_LABEL: "Second Trial"
    ) do
      profile = Provider::PlaidProfile.find("secondary", region: :us)

      assert_equal "secondary-client", profile.client_id
      assert_equal "secondary-secret", profile.secret
      assert_equal "production", profile.environment
      assert_equal "Second Trial", profile.label
    end
  end

  test "does not expose incomplete profiles" do
    with_env_overrides(
      PLAID_PROFILE_INCOMPLETE_CLIENT_ID: "client-only",
      PLAID_PROFILE_INCOMPLETE_SECRET: nil
    ) do
      assert_nil Provider::PlaidProfile.find("incomplete", region: :us)
    end
  end
end
