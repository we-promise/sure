# frozen_string_literal: true

require "test_helper"

class Provider::RevolutXAdapterTest < ActiveSupport::TestCase
  setup do
    @revolut_x_account = revolut_x_accounts(:one)
    @adapter = Provider::RevolutXAdapter.new(@revolut_x_account)
  end

  test "is registered for RevolutXAccount and supports Crypto accounts only" do
    assert_instance_of Provider::RevolutXAdapter, Provider::Factory.create_adapter(@revolut_x_account)
    assert_equal %w[Crypto], Provider::RevolutXAdapter.supported_account_types
  end

  test "offers one fallback connection config when no connection has its API key" do
    family = families(:dylan_family)
    revolut_x_items(:one).update!(api_key: nil)

    configs = Provider::RevolutXAdapter.connection_configs(family: family)

    assert_equal [ "revolut_x" ], configs.map { |config| config[:key] }
    assert_equal "/revolut_x_items/select_accounts?accountable_type=Crypto", configs.first[:new_account_path].call("Crypto", nil)
  end

  test "offers one connection config per credentialed connection" do
    family = families(:dylan_family)
    second = RevolutXItem.create!(family: family, name: "Business", api_key: "c3" * 32)

    configs = Provider::RevolutXAdapter.connection_configs(family: family)

    assert_equal [ "revolut_x_#{second.id}", "revolut_x_#{revolut_x_items(:one).id}" ].sort, configs.map { |config| config[:key] }.sort
    assert_not_includes configs.map { |config| config[:key] }, "revolut_x_#{revolut_x_items(:awaiting_api_key).id}"
    assert_includes configs.first[:existing_account_path].call("acc-1"), "revolut_x_item_id="
  end

  test "sync path points at the item's sync action" do
    assert_equal "/revolut_x_items/#{revolut_x_items(:one).id}/sync", @adapter.sync_path
  end

  test "identifies the provider and its item" do
    assert_equal "revolut_x", @adapter.provider_name
    assert_equal revolut_x_items(:one), @adapter.item
    assert_not @adapter.can_delete_holdings?
  end

  test "falls back to the item's institution details" do
    assert_equal "Revolut X", @adapter.institution_name
    assert_equal "revolut.com", @adapter.institution_domain
    assert_equal "https://exchange.revolut.com", @adapter.institution_url
    assert_equal "#111827", @adapter.institution_color
  end
end
