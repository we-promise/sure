require "test_helper"

class Provider::PlaidAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @plaid_account = plaid_accounts(:one)
    @account = accounts(:depository)
    @adapter = Provider::PlaidAdapter.new(@plaid_account, account: @account)
  end

  def adapter
    @adapter
  end

  # Run shared interface tests
  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  # Provider-specific tests
  test "returns correct provider name" do
    assert_equal "plaid", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "PlaidAccount", @adapter.provider_type
  end

  test "returns plaid item" do
    assert_equal @plaid_account.plaid_item, @adapter.item
  end

  test "returns account" do
    assert_equal @account, @adapter.account
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end
end
