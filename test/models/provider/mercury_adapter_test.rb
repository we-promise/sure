require "test_helper"

class Provider::MercuryAdapterTest < ActiveSupport::TestCase
  test "supports Depository accounts" do
    assert_includes Provider::MercuryAdapter.supported_account_types, "Depository"
  end

  test "does not support Investment accounts" do
    assert_not_includes Provider::MercuryAdapter.supported_account_types, "Investment"
  end

  test "returns connection configs for any family" do
    # Mercury is a per-family provider - any family can connect
    family = families(:dylan_family)
    configs = Provider::MercuryAdapter.connection_configs(family: family)

    assert_equal 1, configs.length
    assert_equal "mercury", configs.first[:key]
    assert_equal "Mercury", configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::MercuryAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when family has no mercury items" do
    family = families(:empty)
    assert_nil Provider::MercuryAdapter.build_provider(family: family)
  end

  test "build_provider returns Mercury provider when credentials configured" do
    family = families(:dylan_family)
    provider = Provider::MercuryAdapter.build_provider(family: family)

    assert_instance_of Provider::Mercury, provider
  end
end
