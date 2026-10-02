require "test_helper"

class Provider::PluggyAdapterTest < ActiveSupport::TestCase
  test "supports Investment accounts" do
    assert_includes Provider::PluggyAdapter.supported_account_types, "Investment"
  end

  test "factory exposes Pluggy for Investment accounts when enabled" do
    family = families(:dylan_family)
    family.stubs(:can_connect_pluggy?).returns(true)

    configs = Provider::Factory.connection_configs_for_account_type(
      account_type: "Investment",
      family: family
    )

    assert configs.any? { |config| config[:key] == "pluggy" }
  end
end
