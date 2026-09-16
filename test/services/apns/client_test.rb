require "test_helper"

class Apns::ClientTest < ActiveSupport::TestCase
  setup do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    @environment = {
      "APNS_ENABLED" => nil,
      "APNS_KEY_ID" => "key-id",
      "APNS_TEAM_ID" => "team-id",
      "APNS_BUNDLE_ID" => "com.example.sure",
      "APNS_PRIVATE_KEY_BASE64" => Base64.strict_encode64("private-key")
    }
  end

  test "sends sandbox notifications with token authentication" do
    connection = mock
    response = stub(ok?: true)
    Apnotic::Connection.expects(:development).with do |options|
      options[:auth_method] == :token &&
        options[:key_id] == "key-id" &&
        options[:team_id] == "team-id" &&
        options[:cert_path].read == "private-key"
    end.returns(connection)
    connection.expects(:push).with do |notification, options|
      options == { timeout: 10 } &&
      notification.topic == "com.example.sure" &&
        notification.push_type == "alert" &&
        notification.custom_payload == { insight_id: "insight-id", destination: "insights" }
    end.returns(response)
    connection.expects(:close)

    ClimateControl.modify(@environment) do
      result = Apns::Client.new(environment: "sandbox").deliver(
        token: "ab" * 32,
        title: "New financial insight",
        body: "Open Sure to review your latest AI insight.",
        insight_id: "insight-id"
      )

      assert result.ok?
    end
  end

  test "sends a bounded production diagnostic without an insight ID" do
    connection = mock
    Apnotic::Connection.expects(:new).returns(connection)
    connection.expects(:push).with do |notification, options|
      notification.custom_payload == { notification_type: "test", destination: "overview" } &&
        notification.apns_collapse_id == "test-request-id" &&
        notification.expiration == 5.minutes.from_now.to_i && options == { timeout: 10 }
    end.returns(stub(ok?: true))
    connection.expects(:close)
    freeze_time do
      ClimateControl.modify(@environment) do
        Apns::Client.new(environment: "production").deliver_test(
          token: "ab" * 32, title: "Test", body: "Test notification", request_id: "request-id"
        )
      end
    end
  end

  test "configured credentials never permit direct sends from self hosted mode" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    Apnotic::Connection.expects(:development).never
    Apnotic::Connection.expects(:new).never
    ClimateControl.modify(@environment) do
      assert Apns::Client.configured?
      refute Apns::Client.available?
      assert_raises(Apns::Client::UnavailableError) do
        Apns::Client.new(environment: "sandbox").deliver_test(
          token: "ab" * 32, title: "Test", body: "Test", request_id: "request-id"
        )
      end
    end
  end

  test "kill switch and absent credentials prevent direct delivery" do
    Apnotic::Connection.expects(:new).never
    ClimateControl.modify(@environment.merge("APNS_ENABLED" => "false")) do
      refute Apns::Client.available?
      assert_raises(Apns::Client::UnavailableError) do
        Apns::Client.new(environment: "production").deliver_test(
          token: "ab" * 32, title: "Test", body: "Test", request_id: "request-id"
        )
      end
    end
    ClimateControl.modify(@environment.merge("APNS_KEY_ID" => nil)) do
      refute Apns::Client.available?
    end
  end

  test "a timeout is retryable and closes the connection" do
    connection = mock
    Apnotic::Connection.expects(:new).returns(connection)
    connection.expects(:push).returns(nil)
    connection.expects(:close)
    ClimateControl.modify(@environment) do
      assert_raises(Apns::Client::TransientError) do
        Apns::Client.new(environment: "production").deliver_test(
          token: "ab" * 32, title: "Test", body: "Test", request_id: "request-id"
        )
      end
    end
  end
end
