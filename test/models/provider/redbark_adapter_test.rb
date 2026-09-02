require "test_helper"

class Provider::RedbarkAdapterTest < ActiveSupport::TestCase
  test "supports Depository accounts" do
    assert_includes Provider::RedbarkAdapter.supported_account_types, "Depository"
  end

  test "does not support Investment accounts" do
    assert_not_includes Provider::RedbarkAdapter.supported_account_types, "Investment"
  end

  test "returns connection config for families" do
    configs = Provider::RedbarkAdapter.connection_configs(family: families(:empty))

    assert_equal 1, configs.length
    assert_equal "redbark", configs.first[:key]
    assert configs.first[:can_connect]
  end

  test "builds provider with valid credentials" do
    provider = Provider::RedbarkAdapter.build_provider(family: families(:dylan_family))

    assert_instance_of Provider::Redbark, provider
  end

  test "returns nil without credentials" do
    assert_nil Provider::RedbarkAdapter.build_provider(family: families(:empty))
  end

  test "returns nil without family" do
    assert_nil Provider::RedbarkAdapter.build_provider(family: nil)
  end
end
