require "uri"

require "test_helper"

class Provider::MercuryAdapterTest < ActiveSupport::TestCase
  test "supports Depository accounts" do
    assert_includes Provider::MercuryAdapter.supported_account_types, "Depository"
  end

  test "does not support Investment accounts" do
    assert_not_includes Provider::MercuryAdapter.supported_account_types, "Investment"
  end

  test "returns fallback connection config when no credentials exist yet" do
    # Mercury is a per-family provider - any family can connect
    family = families(:empty)
    configs = Provider::MercuryAdapter.connection_configs(family: family)

    assert_equal 1, configs.length
    assert_equal "mercury", configs.first[:key]
    assert_equal I18n.t("mercury_items.provider_connection.default_name"), configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "returns one connection config per credentialed mercury item" do
    family = families(:dylan_family)
    first_item = mercury_items(:one)
    second_item = MercuryItem.create!(
      family: family,
      name: "Business Mercury",
      token: "second_mercury_token",
      base_url: "https://api.mercury.com/api/v1"
    )

    configs = Provider::MercuryAdapter.connection_configs(family: family)

    assert_equal 2, configs.length
    assert_equal [ "mercury_#{second_item.id}", "mercury_#{first_item.id}" ], configs.map { |config| config[:key] }
    assert_equal [
      I18n.t("mercury_items.provider_connection.name", name: second_item.name),
      I18n.t("mercury_items.provider_connection.name", name: first_item.name)
    ], configs.map { |config| config[:name] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Depository", "/accounts"))
    assert_equal "/mercury_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "mercury_item_id=#{second_item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:depository).id))
    assert_equal "/mercury_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "mercury_item_id=#{second_item.id}"
  end

  test "connection configs ignore items with whitespace-only tokens" do
    family = families(:dylan_family)
    MercuryItem.create!(
      family: family,
      name: "Blank Mercury",
      token: "temporary_token",
      base_url: "https://api.mercury.com/api/v1"
    ).update_column(:token, "   ")

    configs = Provider::MercuryAdapter.connection_configs(family: family)

    assert_equal [ "mercury_#{mercury_items(:one).id}" ], configs.map { |config| config[:key] }
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

  test "build_provider uses explicit mercury item credentials" do
    family = families(:dylan_family)
    second_item = MercuryItem.create!(
      family: family,
      name: "Business Mercury",
      token: "second_mercury_token",
      base_url: "https://api.mercury.com/api/v1"
    )

    provider = Provider::MercuryAdapter.build_provider(family: family, mercury_item_id: second_item.id)

    assert_instance_of Provider::Mercury, provider
    assert_equal "second_mercury_token", provider.token
    assert_equal "https://api.mercury.com/api/v1", provider.base_url
  end

  test "build_provider strips surrounding token whitespace" do
    family = families(:dylan_family)
    second_item = MercuryItem.create!(
      family: family,
      name: "Business Mercury",
      token: " second_mercury_token \n",
      base_url: "https://api.mercury.com/api/v1"
    )

    provider = Provider::MercuryAdapter.build_provider(family: family, mercury_item_id: second_item.id)

    assert_equal "second_mercury_token", provider.token
  end

  test "build_provider refuses mercury items outside the family" do
    family = families(:dylan_family)
    other_item = MercuryItem.create!(
      family: families(:empty),
      name: "Other Mercury",
      token: "other_mercury_token",
      base_url: "https://api.mercury.com/api/v1"
    )

    assert_nil Provider::MercuryAdapter.build_provider(family: family, mercury_item_id: other_item.id)
  end

  test "build_provider refuses explicit mercury item without usable credentials" do
    family = families(:dylan_family)
    blank_item = MercuryItem.create!(
      family: family,
      name: "Blank Mercury",
      token: "temporary_token",
      base_url: "https://api.mercury.com/api/v1"
    )
    blank_item.update_column(:token, "   ")

    assert_nil Provider::MercuryAdapter.build_provider(family: family, mercury_item_id: blank_item.id)
  end
end
