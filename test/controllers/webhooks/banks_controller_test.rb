require "test_helper"

class WebhooksBanksControllerTest < ActionDispatch::IntegrationTest
  class VerifyingProvider
    def initialize(credentials)
      @secret = credentials[:webhook_signing_secret]
    end

    def verify_webhook_signature!(raw_body, headers)
      # accept when header matches secret for simplicity
      (headers["X-Test-Signature"] || headers["HTTP_X_TEST_SIGNATURE"]) == @secret
    end
  end

  setup do
    @family = families(:dylan_family)
  end

  test "webhook schedules sync for matching connection" do
    Provider::Banks::Registry.stubs(:find).returns(Data.define(:key, :display_name, :credential_fields, :capabilities, :provider_class, :mapper_class).new(
      :test, "Test", [], [], VerifyingProvider, Provider::Banks::Mapper
    ))

    conn = @family.bank_connections.create!(name: "Test", provider: :test, credentials: { webhook_signing_secret: "abc" }.to_json)

    assert_difference -> { conn.syncs.count }, +1 do
      post "/webhooks/banks/test", params: { event: "ping" }.to_json, headers: { "Content-Type" => "application/json", "X-Test-Signature" => "abc" }
      assert_response :ok
    end
  end
end
