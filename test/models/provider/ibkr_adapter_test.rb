require "test_helper"

class Provider::IbkrAdapterTest < ActiveSupport::TestCase
  test "returns a single generic connection config with one ibkr item" do
    family = families(:dylan_family)

    configs = Provider::IbkrAdapter.connection_configs(family: family)

    assert_equal 1, configs.length
    assert_equal "ibkr", configs.first[:key]
    assert_equal I18n.t("providers.ibkr.name"), configs.first[:name]
    assert_equal Rails.application.routes.url_helpers.select_accounts_ibkr_items_path,
                 configs.first[:new_account_path].call("Investment", nil)
  end

  test "returns one connection config per credentialed ibkr item" do
    family = families(:dylan_family)
    first_item = ibkr_items(:configured_item)
    second_item = family.ibkr_items.create!(name: "IBKR Ireland", query_id: "Q2", token: "T2")

    configs = Provider::IbkrAdapter.connection_configs(family: family)

    assert_equal 2, configs.length
    assert_equal [ "ibkr_#{first_item.id}", "ibkr_#{second_item.id}" ].sort, configs.map { |c| c[:key] }.sort

    second_config = configs.find { |c| c[:key] == "ibkr_#{second_item.id}" }
    assert_equal I18n.t("providers.ibkr.named_connection", name: "IBKR Ireland"), second_config[:name]
    assert_equal Rails.application.routes.url_helpers.select_accounts_ibkr_items_path(ibkr_item_id: second_item.id),
                 second_config[:new_account_path].call("Investment", nil)
    assert_equal Rails.application.routes.url_helpers.select_existing_account_ibkr_items_path(account_id: "acc-1", ibkr_item_id: second_item.id),
                 second_config[:existing_account_path].call("acc-1")
  end

  test "ignores items scheduled for deletion" do
    family = families(:dylan_family)
    family.ibkr_items.create!(name: "Old IBKR", query_id: "Q2", token: "T2", scheduled_for_deletion: true)

    configs = Provider::IbkrAdapter.connection_configs(family: family)

    assert_equal [ "ibkr" ], configs.map { |c| c[:key] }
  end
end
