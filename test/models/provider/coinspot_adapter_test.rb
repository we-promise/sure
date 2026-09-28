# frozen_string_literal: true

require "test_helper"
require "uri"

class Provider::CoinspotAdapterTest < ActiveSupport::TestCase
  setup do
    coinspot_items(:requires_update).update!(scheduled_for_deletion: true)
  end

  test "supports Crypto accounts only" do
    assert_includes Provider::CoinspotAdapter.supported_account_types, "Crypto"
    assert_not_includes Provider::CoinspotAdapter.supported_account_types, "Depository"
  end

  test "returns fallback connection config when no credentials exist yet" do
    family = families(:empty)
    configs = Provider::CoinspotAdapter.connection_configs(family: family)

    assert_equal 1, configs.length
    assert_equal "coinspot", configs.first[:key]
    assert_equal I18n.t("coinspot_items.provider_connection.default_name"), configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "returns one connection config per credentialed coinspot item" do
    family = families(:dylan_family)
    first_item = coinspot_items(:one)
    second_item = CoinspotItem.create!(
      family: family,
      name: "Business CoinSpot",
      api_key: "second_coinspot_key",
      api_secret: "second_coinspot_secret"
    )

    configs = Provider::CoinspotAdapter.connection_configs(family: family)

    assert_equal [ "coinspot_#{second_item.id}", "coinspot_#{first_item.id}" ], configs.map { |config| config[:key] }
    assert_equal [
      I18n.t("coinspot_items.provider_connection.name", name: second_item.name),
      I18n.t("coinspot_items.provider_connection.name", name: first_item.name)
    ], configs.map { |config| config[:name] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Crypto", "/accounts"))
    assert_equal "/coinspot_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "coinspot_item_id=#{second_item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:crypto).id))
    assert_equal "/coinspot_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "coinspot_item_id=#{second_item.id}"
  end

  test "connection configs ignore whitespace-only credentials" do
    family = families(:dylan_family)
    blank_item = CoinspotItem.create!(
      family: family,
      name: "Blank CoinSpot",
      api_key: "temporary_key",
      api_secret: "temporary_secret"
    )
    blank_item.update_columns(api_key: "   ", api_secret: "   ")

    configs = Provider::CoinspotAdapter.connection_configs(family: family)

    assert_equal [ "coinspot_#{coinspot_items(:one).id}" ], configs.map { |config| config[:key] }
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::CoinspotAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when family has no coinspot items" do
    assert_nil Provider::CoinspotAdapter.build_provider(family: families(:empty))
  end

  test "build_provider returns CoinSpot provider when only one credentialed item exists" do
    provider = Provider::CoinspotAdapter.build_provider(family: families(:dylan_family))

    assert_instance_of Provider::Coinspot, provider
  end

  test "build_provider requires explicit item when multiple credentialed items exist" do
    family = families(:dylan_family)
    CoinspotItem.create!(
      family: family,
      name: "Second CoinSpot",
      api_key: "second_coinspot_key",
      api_secret: "second_coinspot_secret"
    )

    assert_nil Provider::CoinspotAdapter.build_provider(family: family)
  end

  test "build_provider uses explicit coinspot item credentials" do
    family = families(:dylan_family)
    second_item = CoinspotItem.create!(
      family: family,
      name: "Second CoinSpot",
      api_key: " second_coinspot_key \n",
      api_secret: " second_coinspot_secret \n"
    )

    provider = Provider::CoinspotAdapter.build_provider(family: family, coinspot_item_id: second_item.id)

    assert_instance_of Provider::Coinspot, provider
    assert_equal "second_coinspot_key", provider.api_key
    assert_equal "second_coinspot_secret", provider.api_secret
  end

  test "build_provider refuses coinspot items outside the family" do
    family = families(:dylan_family)
    other_item = CoinspotItem.create!(
      family: families(:empty),
      name: "Other CoinSpot",
      api_key: "other_coinspot_key",
      api_secret: "other_coinspot_secret"
    )

    assert_nil Provider::CoinspotAdapter.build_provider(family: family, coinspot_item_id: other_item.id)
  end

  test "build_provider refuses explicit coinspot item without usable credentials" do
    family = families(:dylan_family)
    blank_item = CoinspotItem.create!(
      family: family,
      name: "Blank CoinSpot",
      api_key: "temporary_key",
      api_secret: "temporary_secret"
    )
    blank_item.update_columns(api_key: "   ", api_secret: "   ")

    assert_nil Provider::CoinspotAdapter.build_provider(family: family, coinspot_item_id: blank_item.id)
  end
end
