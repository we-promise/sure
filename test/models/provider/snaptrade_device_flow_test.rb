require "test_helper"
require "ostruct"

# The device-flow SnapTrade client: the OAuth ceremony it drives, and the
# credential binding and hash normalization that let it stand in for the
# deprecated PKCE client behind one interface.
class Provider::SnaptradeDeviceFlowTest < ActiveSupport::TestCase
  setup do
    @original = Rails.configuration.x.snaptrade
    Rails.configuration.x.snaptrade = ActiveSupport::OrderedOptions.new
  end

  teardown do
    Rails.configuration.x.snaptrade = @original
  end

  def faraday_response(status:, body:)
    OpenStruct.new(status: status, body: body, success?: (200..299).cover?(status), reason_phrase: "Bad Request")
  end

  def client(user_id: "u-1", user_secret: "s-1")
    Provider::Snaptrade.new(
      client_id: "cid", consumer_key: "ck", user_id: user_id, user_secret: user_secret
    )
  end

  # Stands in for a SnapTrade SDK model, which exposes its wire shape through
  # to_hash rather than being a Hash itself.
  class SdkModel
    def initialize(attributes) = @attributes = attributes
    def to_hash = @attributes
  end

  # --- Configuration ---

  test "oauth_client_id_configured? follows the deployment's public client id" do
    assert_not Provider::Snaptrade.oauth_client_id_configured?

    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    assert Provider::Snaptrade.oauth_client_id_configured?
  end

  test "api credentials must be given as a pair" do
    assert_nothing_raised { Provider::Snaptrade.new }
    assert_raises(Provider::Snaptrade::ConfigurationError) { Provider::Snaptrade.new(client_id: "cid") }
    assert_raises(Provider::Snaptrade::ConfigurationError) { Provider::Snaptrade.new(consumer_key: "ck") }
  end

  test "data calls refuse to run without a registered user" do
    provider = Provider::Snaptrade.new(client_id: "cid", consumer_key: "ck")

    assert_raises(Provider::Snaptrade::ConfigurationError) { provider.list_accounts }
  end

  # --- Device flow ---

  # Records what the provider builds into a Faraday request
  class RequestRecorder
    attr_reader :headers, :body

    def initialize
      @headers = {}
    end

    def body=(value)
      @body = value
    end
  end

  test "start_device_authorization posts the public client id to the discovered endpoint" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    provider = Provider::Snaptrade.new
    request = RequestRecorder.new

    connection = mock("faraday")
    connection.expects(:get)
      .with(Provider::Snaptrade::OAUTH_DISCOVERY_URL)
      .returns(faraday_response(status: 200, body: {
        "device_authorization_endpoint" => "https://api.snaptrade.com/oauth/device/",
        "token_endpoint" => "https://api.snaptrade.com/oauth/token/"
      }.to_json))
    connection.expects(:post)
      .with("https://api.snaptrade.com/oauth/device/")
      .yields(request)
      .returns(faraday_response(status: 200, body: { "device_code" => "dc", "user_code" => "ABCD" }.to_json))
    provider.stubs(:oauth_connection).returns(connection)

    result = provider.start_device_authorization

    assert_equal "dc", result["device_code"]
    assert_equal "ABCD", result["user_code"]
    assert_equal(
      { "client_id" => "public-client-id", "scope" => "read" },
      Rack::Utils.parse_query(request.body)
    )
  end

  test "poll_device_token sends the device-code grant" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    provider = Provider::Snaptrade.new
    request = RequestRecorder.new

    connection = mock("faraday")
    connection.stubs(:get).returns(faraday_response(status: 200, body: {
      "token_endpoint" => "https://api.snaptrade.com/oauth/token/"
    }.to_json))
    connection.expects(:post)
      .with("https://api.snaptrade.com/oauth/token/")
      .yields(request)
      .returns(faraday_response(status: 200, body: { "access_token" => "at" }.to_json))
    provider.stubs(:oauth_connection).returns(connection)

    assert_equal "at", provider.poll_device_token(device_code: "dc")["access_token"]
    assert_equal(
      {
        "grant_type" => Provider::Snaptrade::DEVICE_CODE_GRANT,
        "device_code" => "dc",
        "client_id" => "public-client-id"
      },
      Rack::Utils.parse_query(request.body)
    )
  end

  test "the discovery document is fetched once per client" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    provider = Provider::Snaptrade.new

    connection = mock("faraday")
    connection.expects(:get).once.returns(faraday_response(status: 200, body: {
      "device_authorization_endpoint" => "https://api.snaptrade.com/oauth/device/",
      "token_endpoint" => "https://api.snaptrade.com/oauth/token/"
    }.to_json))
    provider.stubs(:oauth_connection).returns(connection)

    2.times { provider.oauth_authorization_server_metadata }
  end

  test "device flow raises before any request when the public client id is missing" do
    provider = Provider::Snaptrade.new
    connection = mock("faraday")
    connection.expects(:get).never
    connection.expects(:post).never
    provider.stubs(:oauth_connection).returns(connection)

    assert_raises(Provider::Snaptrade::ConfigurationError) { provider.start_device_authorization }
    assert_raises(Provider::Snaptrade::ConfigurationError) { provider.poll_device_token(device_code: "dc") }
  end

  test "poll_device_token requires a device code" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"

    assert_raises(Provider::Snaptrade::ConfigurationError) do
      Provider::Snaptrade.new.poll_device_token(device_code: "")
    end
  end

  test "an OAuth error response surfaces the error description" do
    Rails.configuration.x.snaptrade.oauth_client_id = "public-client-id"
    provider = Provider::Snaptrade.new

    connection = mock("faraday")
    connection.stubs(:get).returns(faraday_response(status: 200, body: {
      "device_authorization_endpoint" => "https://api.snaptrade.com/oauth/device/"
    }.to_json))
    connection.stubs(:post).returns(faraday_response(
      status: 400, body: { "error" => "authorization_pending", "error_description" => "Not yet approved" }.to_json
    ))
    provider.stubs(:oauth_connection).returns(connection)

    error = assert_raises(Provider::Snaptrade::ApiError) { provider.start_device_authorization }
    assert_match "Not yet approved", error.message
    assert_equal 400, error.status_code
  end

  # --- Data methods ---

  test "data calls bind the registered user and return plain hashes" do
    provider = client
    account_information = mock("account_information")
    account_information.expects(:list_user_accounts)
      .with(user_id: "u-1", user_secret: "s-1")
      .returns([ SdkModel.new("id" => "acct-1", "name" => "Brokerage") ])
    provider.stubs(:client).returns(OpenStruct.new(account_information: account_information))

    accounts = provider.list_accounts

    assert_equal 1, accounts.size
    assert_instance_of Hash, accounts.first
    assert_equal "acct-1", accounts.first["id"]
  end

  test "get_account_activities passes through the date window" do
    provider = client
    account_information = mock("account_information")
    account_information.expects(:get_account_activities)
      .with(
        user_id: "u-1", user_secret: "s-1", account_id: "acct-1",
        start_date: "2026-01-01", end_date: "2026-02-01"
      )
      .returns(SdkModel.new("data" => [ SdkModel.new("id" => "act-1") ]))
    provider.stubs(:client).returns(OpenStruct.new(account_information: account_information))

    response = provider.get_account_activities(
      account_id: "acct-1", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 2, 1)
    )

    assert_equal [ { "id" => "act-1" } ], response["data"]
  end

  test "SDK errors are mapped onto the shared error hierarchy" do
    provider = client
    account_information = mock("account_information")
    account_information.stubs(:list_user_accounts).raises(SnapTrade::ApiError.new(code: 401, response_body: "{}"))
    provider.stubs(:client).returns(OpenStruct.new(account_information: account_information))

    assert_raises(Provider::Snaptrade::AuthenticationError) { provider.list_accounts }
  end

  test "rate limits keep their status code" do
    provider = client
    account_information = mock("account_information")
    account_information.stubs(:list_user_accounts).raises(SnapTrade::ApiError.new(code: 429, response_body: "{}"))
    provider.stubs(:client).returns(OpenStruct.new(account_information: account_information))

    error = assert_raises(Provider::Snaptrade::ApiError) { provider.list_accounts }
    assert_equal 429, error.status_code
  end

  # register_user is a non-idempotent create whose user_secret comes back once,
  # so a timed-out request must never be replayed.
  test "register_user is not retried on a network timeout" do
    provider = client
    authentication = mock("authentication")
    authentication.expects(:register_snap_trade_user).once.raises(Faraday::TimeoutError.new("timeout"))
    provider.stubs(:client).returns(OpenStruct.new(authentication: authentication))

    assert_raises(Provider::Snaptrade::ApiError) { provider.register_user("family_1_2") }
  end
end
