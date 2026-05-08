require "uri"

require "test_helper"

class Provider::SophtronAdapterTest < ActiveSupport::TestCase
  test "new account connection config starts a new institution connection" do
    config = Provider::SophtronAdapter.connection_configs(family: families(:empty)).first

    new_account_uri = URI.parse(config[:new_account_path].call("Depository", "/accounts"))

    assert_equal "/sophtron_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "accountable_type=Depository"
    assert_includes new_account_uri.query, "return_to=%2Faccounts"
    assert_includes new_account_uri.query, "connect_new_institution=true"
  end

  test "institution_name does not fall back to another institution item" do
    item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron Connection",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      institution_name: "Amazon",
      user_institution_id: "ui-amazon"
    )
    account = item.sophtron_accounts.create!(
      name: "Juan",
      account_id: "card-1",
      currency: "USD",
      balance: 1_947.18,
      institution_metadata: { user_institution_id: "ui-apple" }
    )

    assert_nil Provider::SophtronAdapter.new(account).institution_name
  end
end
