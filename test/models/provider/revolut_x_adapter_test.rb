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

  test "has no connection configs until the connection UI exists" do
    assert_equal [], Provider::RevolutXAdapter.connection_configs(family: families(:dylan_family))
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
