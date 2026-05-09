require "test_helper"

class Webhooks::ProviderControllerTest < ActionDispatch::IntegrationTest
  # Define stable stub classes (constants — not Class.new in setup) so mocha's
  # any_instance binds to the same class across the controller's two lookups.
  class StubHandler
    def initialize(raw_body:, headers:); end
    def process; end
  end

  class StubAdapter
    def self.verify_webhook!(headers:, raw_body:); end
    def self.webhook_handler_class = ::Webhooks::ProviderControllerTest::StubHandler
  end

  setup do
    Provider::ConnectionRegistry.stubs(:adapter_for).with("plaid").returns(StubAdapter)
  end

  test "returns 200 when signature verifies and handler runs" do
    StubAdapter.expects(:verify_webhook!).once
    StubHandler.any_instance.expects(:process).once

    post webhooks_provider_path(provider_key: "plaid"),
         headers: { "Content-Type" => "application/json" },
         params: { item_id: "x" }.to_json
    assert_response :ok
  end

  test "returns 400 on signature failure" do
    StubAdapter.expects(:verify_webhook!).raises(StandardError, "bad sig")
    StubHandler.any_instance.expects(:process).never

    post webhooks_provider_path(provider_key: "plaid"),
         headers: { "Content-Type" => "application/json" },
         params: "{}"
    assert_response :bad_request
  end

  test "returns 200 on handler error (avoids upstream 24h retry)" do
    StubAdapter.expects(:verify_webhook!).once
    StubHandler.any_instance.expects(:process).raises(StandardError, "handler bug")
    Sentry.expects(:capture_exception).at_least_once

    post webhooks_provider_path(provider_key: "plaid"),
         headers: { "Content-Type" => "application/json" },
         params: "{}"
    assert_response :ok
  end

  test "returns 404 for unknown provider_key" do
    Provider::ConnectionRegistry.stubs(:adapter_for).with("unknown")
                                .raises(NotImplementedError, "No connection adapter registered for: unknown")

    post webhooks_provider_path(provider_key: "unknown"),
         headers: { "Content-Type" => "application/json" },
         params: "{}"
    assert_response :not_found
  end

  test "returns 400 when adapter does not accept webhooks" do
    StubAdapter.expects(:verify_webhook!).raises(NotImplementedError, "Provider does not accept webhooks")

    post webhooks_provider_path(provider_key: "plaid"),
         headers: { "Content-Type" => "application/json" },
         params: "{}"
    assert_response :bad_request
  end
end
