require "test_helper"

class Provider::SnaptradeTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Snaptrade.new(client_id: "test_client_id", consumer_key: "test_consumer_key")
  end

  test "personal_key_error? detects SnapTrade error code 1012" do
    assert @provider.send(:personal_key_error?, 400, '{"code":"1012","detail":"nope"}', "Bad Request")
  end

  test "personal_key_error? detects the descriptive personal key message" do
    message = "registerUser is not available for personal keys"
    assert @provider.send(:personal_key_error?, 400, "", message)
  end

  test "personal_key_error? ignores unrelated 400s and non-400 statuses" do
    assert_not @provider.send(:personal_key_error?, 400, "some other validation error", "Bad Request")
    assert_not @provider.send(:personal_key_error?, 401, '{"code":"1012"}', "")
  end

  test "handle_api_error raises PersonalKeyError for personal key responses" do
    error = OpenStruct.new(
      code: 400,
      response_body: '{"code":"1012","detail":"registerUser is not available for personal keys"}',
      message: "Bad Request"
    )

    assert_raises(Provider::Snaptrade::PersonalKeyError) do
      @provider.send(:handle_api_error, error, "register_user")
    end
  end

  test "handle_api_error still maps auth failures to AuthenticationError" do
    error = OpenStruct.new(code: 401, response_body: "", message: "Unauthorized")

    assert_raises(Provider::Snaptrade::AuthenticationError) do
      @provider.send(:handle_api_error, error, "list_connections")
    end
  end
end
