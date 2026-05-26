require "test_helper"
require "uri"

class Provider::AkahuAdapterTest < ActiveSupport::TestCase
  test "supports Investment accounts" do
    assert_includes Provider::AkahuAdapter.supported_account_types, "Investment"
  end

  test "returns one connection config per credentialed Akahu item" do
    family = families(:dylan_family)
    first_item = AkahuItem.create!(
      family: family,
      name: "Main Akahu",
      app_token: "app-token",
      user_token: "user-token"
    )
    second_item = AkahuItem.create!(
      family: family,
      name: "Secondary Akahu",
      app_token: "second-app-token",
      user_token: "second-user-token"
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
end
