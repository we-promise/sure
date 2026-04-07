require "test_helper"

class FeatureFlagsTest < ActiveSupport::TestCase
  test "db_sso_providers? is true when AUTH_PROVIDERS_SOURCE is db in production" do
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => "db") do
      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
      assert FeatureFlags.db_sso_providers?
    end
  end

  test "db_sso_providers? defaults to yaml in production when AUTH_PROVIDERS_SOURCE is unset" do
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => nil) do
      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("production"))
      assert_not FeatureFlags.db_sso_providers?
    end
  end

  test "db_sso_providers? defaults to db for self hosted mode outside production" do
    with_env_overrides("AUTH_PROVIDERS_SOURCE" => nil) do
      Rails.stubs(:env).returns(ActiveSupport::StringInquirer.new("development"))
      with_self_hosting do
        assert FeatureFlags.db_sso_providers?
      end
    end
  end
end
