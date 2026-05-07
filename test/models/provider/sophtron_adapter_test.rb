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
end
