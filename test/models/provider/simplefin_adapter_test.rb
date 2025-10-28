require "test_helper"

class Provider::SimplefinAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Bank",
      access_url: "https://example.com/access_token"
    )
    @simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "SimpleFin Depository Account",
      account_id: "sf_mock_1",
      account_type: "checking",
      currency: "USD",
      current_balance: 1000,
      available_balance: 1000,
      org_data: {
        "name" => "SimpleFin Test Bank",
        "domain" => "testbank.com",
        "url" => "https://testbank.com"
      }
    )
    @account = accounts(:depository)
    @adapter = Provider::SimplefinAdapter.new(@simplefin_account, account: @account)
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
    assert_equal "simplefin", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "SimplefinAccount", @adapter.provider_type
  end

  test "returns simplefin item" do
    assert_equal @simplefin_account.simplefin_item, @adapter.item
  end

  test "returns account" do
    assert_equal @account, @adapter.account
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end

  test "parses institution domain from org_data" do
    assert_equal "testbank.com", @adapter.institution_domain
  end

  test "parses institution name from org_data" do
    assert_equal "SimpleFin Test Bank", @adapter.institution_name
  end

  test "parses institution url from org_data" do
    assert_equal "https://testbank.com", @adapter.institution_url
  end
end
