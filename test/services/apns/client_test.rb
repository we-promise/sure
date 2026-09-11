require "test_helper"

class Apns::ClientTest < ActiveSupport::TestCase
  setup do
    @environment = {
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
    connection.expects(:push).with do |notification|
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
end
