require "test_helper"

class PlaidItemTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  setup do
    @plaid_item = @syncable = plaid_items(:one)
    @plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_provider)
  end

  test "removes plaid item when destroyed" do
    @plaid_provider.expects(:remove_item).with(@plaid_item.access_token).once

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "destroys item even when Plaid credentials are invalid" do
    error_response = {
      "error_code" => "INVALID_API_KEYS",
      "error_message" => "invalid client_id or secret provided"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "destroys item even when Plaid item not found" do
    error_response = {
      "error_code" => "ITEM_NOT_FOUND",
      "error_message" => "item not found"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end
end
