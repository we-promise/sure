require "test_helper"

class Provider::LunchflowAdapterTest < ActiveSupport::TestCase
  test "supports Investment accounts" do
    assert_includes Provider::LunchflowAdapter.supported_account_types, "Investment"
  end
end
