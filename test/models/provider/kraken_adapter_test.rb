# frozen_string_literal: true

require "test_helper"
require "uri"

class Provider::KrakenAdapterTest < ActiveSupport::TestCase
  setup do
    kraken_items(:requires_update).update!(scheduled_for_deletion: true)
  end

  test "supports Crypto accounts only" do
    assert_includes Provider::KrakenAdapter.supported_account_types, "Crypto"
    assert_not_includes Provider::KrakenAdapter.supported_account_types, "Depository"
  end

  test "returns fallback connection config when no credentials exist yet" do
    family = families(:empty)
    configs = Provider::KrakenAdapter.connection_configs(family: family)

    assert_equal 1, configs.length
    assert_equal "kraken", configs.first[:key]
    assert_equal I18n.t("kraken_items.provider_connection.default_name"), configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "returns one connection config per credentialed kraken item" do
    family = families(:dylan_family)
    first_item = kraken_items(:one)
    second_item = KrakenItem.create!(
      family: family,
      name: "Business Kraken",
      api_key: "second_kraken_key",
      api_secret: "second_kraken_secret"
    )

    configs = Provider::KrakenAdapter.connection_configs(family: family)

    assert_equal [ "kraken_#{second_item.id}", "kraken_#{first_item.id}" ], configs.map { |config| config[:key] }
    assert_equal [
      I18n.t("kraken_items.provider_connection.name", name: second_item.name),
      I18n.t("kraken_items.provider_connection.name", name: first_item.name)
    ], configs.map { |config| config[:name] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Crypto", "/accounts"))
    assert_equal "/kraken_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "kraken_item_id=#{second_item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:crypto).id))
    assert_equal "/kraken_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "kraken_item_id=#{second_item.id}"
  end

  test "connection configs ignore whitespace-only credentials" do
    family = families(:dylan_family)
    blank_item = KrakenItem.create!(
      family: family,
      name: "Blank Kraken",
      api_key: "temporary_key",
      api_secret: "temporary_secret"
    )
    blank_item.update_columns(api_key: "   ", api_secret: "   ")

    configs = Provider::KrakenAdapter.connection_configs(family: family)

    assert_equal [ "kraken_#{kraken_items(:one).id}" ], configs.map { |config| config[:key] }
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::KrakenAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when family has no kraken items" do
    assert_nil Provider::KrakenAdapter.build_provider(family: families(:empty))
  end

  test "build_provider returns Kraken provider when only one credentialed item exists" do
    provider = Provider::KrakenAdapter.build_provider(family: families(:dylan_family))

    assert_instance_of Provider::Kraken, provider
  end

  test "build_provider requires explicit item when multiple credentialed items exist" do
    family = families(:dylan_family)
    KrakenItem.create!(
      family: family,
      name: "Second Kraken",
      api_key: "second_kraken_key",
      api_secret: "second_kraken_secret"
    )

    assert_nil Provider::KrakenAdapter.build_provider(family: family)
  end

  test "build_provider uses explicit kraken item credentials" do
    family = families(:dylan_family)
    second_item = KrakenItem.create!(
      family: family,
      name: "Second Kraken",
      api_key: " second_kraken_key \n",
      api_secret: " second_kraken_secret \n"
    )

    provider = Provider::KrakenAdapter.build_provider(family: family, kraken_item_id: second_item.id)

    assert_instance_of Provider::Kraken, provider
    assert_equal "second_kraken_key", provider.api_key
    assert_equal "second_kraken_secret", provider.api_secret
  end

  test "build_provider refuses kraken items outside the family" do
    family = families(:dylan_family)
    other_item = KrakenItem.create!(
      family: families(:empty),
      name: "Other Kraken",
      api_key: "other_kraken_key",
      api_secret: "other_kraken_secret"
    )

    assert_nil Provider::KrakenAdapter.build_provider(family: family, kraken_item_id: other_item.id)
  end

  test "build_provider refuses explicit kraken item without usable credentials" do
    family = families(:dylan_family)
    blank_item = KrakenItem.create!(
      family: family,
      name: "Blank Kraken",
      api_key: "temporary_key",
      api_secret: "temporary_secret"
    )
    blank_item.update_columns(api_key: "   ", api_secret: "   ")

    assert_nil Provider::KrakenAdapter.build_provider(family: family, kraken_item_id: blank_item.id)
  end
end
