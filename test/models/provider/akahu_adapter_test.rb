require "test_helper"

class Provider::AkahuAdapterTest < ActiveSupport::TestCase
  test "supports Investment accounts" do
    assert_includes Provider::AkahuAdapter.supported_account_types, "Investment"
  end
end
