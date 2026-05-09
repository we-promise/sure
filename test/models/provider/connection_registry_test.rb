require "test_helper"

class Provider::ConnectionRegistryTest < ActiveSupport::TestCase
  test "framework_key_for returns the framework key when given the framework key" do
    assert_equal "plaid",     Provider::ConnectionRegistry.framework_key_for("plaid")
    assert_equal "truelayer", Provider::ConnectionRegistry.framework_key_for("truelayer")
  end

  test "framework_key_for resolves a legacy config_key to its owning framework key" do
    # Plaid declares ['plaid', 'plaid_eu'] as legacy_config_keys.
    assert_equal "plaid", Provider::ConnectionRegistry.framework_key_for("plaid_eu")
  end

  test "framework_key_for returns nil for an unknown key" do
    assert_nil Provider::ConnectionRegistry.framework_key_for("not_a_real_provider")
  end

  test "framework_key_for is symbol-tolerant" do
    assert_equal "plaid", Provider::ConnectionRegistry.framework_key_for(:plaid)
  end
end
