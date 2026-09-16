require "test_helper"
require "uri"
require_relative "../../support/provider_ingestion_test_helper"

class Provider::AkahuAdapterTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  test "supports Investment accounts" do
    assert_includes Provider::AkahuAdapter.supported_account_types, "Investment"
  end

  test "returns one connection config per credentialed Akahu item" do
    family = families(:dylan_family)
    first_item = AkahuItem.create!(
      family: family,
      name: "Main Akahu",
      app_token: "akahu-app-credential",
      user_token: "akahu-user-credential"
    )
    second_item = AkahuItem.create!(
      family: family,
      name: "Secondary Akahu",
      app_token: "second-akahu-app-credential",
      user_token: "second-akahu-user-credential"
    )

    configs = Provider::AkahuAdapter.connection_configs(family: family)

    assert_equal [ "akahu_#{second_item.id}", "akahu_#{first_item.id}" ], configs.map { |config| config[:key] }
    assert_equal [ second_item.name, first_item.name ], configs.map { |config| config[:name] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Depository", "/accounts"))
    assert_equal "/akahu_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "akahu_item_id=#{second_item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:depository).id))
    assert_equal "/akahu_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "akahu_item_id=#{second_item.id}"
  end

  test "legacy pickers and client resolution exclude native and transitional owners" do
    with_provider_encryption do
      family = families(:dylan_family)
      item = family.akahu_items.create!(name: "Migrating Akahu", app_token: "app-credential", user_token: "user-credential")
      control = ProviderMigrationControl.create!(family: family, provider_key: "akahu", legacy_type: "AkahuItem", legacy_id: item.id)

      %w[legacy copying shadow failed].each do |state|
        control.update!(state: state)
        assert_equal [ "akahu_#{item.id}" ], Provider::AkahuAdapter.connection_configs(family: family).map { |config| config[:key] }
        assert_instance_of Provider::Akahu, Provider::AkahuAdapter.build_provider(family: family, akahu_item_id: item.id)
      end
      %w[quiescing active rollback_pending retired].each do |state|
        control.update!(state: state)
        assert_empty Provider::AkahuAdapter.connection_configs(family: family)
        assert_nil Provider::AkahuAdapter.build_provider(family: family, akahu_item_id: item.id)
        assert_nil Provider::AkahuAdapter.build_provider(family: family)
      end
    end
  end
end
