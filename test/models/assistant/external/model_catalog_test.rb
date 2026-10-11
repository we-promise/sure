require "test_helper"

class Assistant::External::ModelCatalogTest < ActiveSupport::TestCase
  test "discovers gateway agents from the OpenAI models endpoint" do
    request = stub_request(:get, "https://agent.example.com/v1/models")
      .with(headers: { "Authorization" => "Bearer secret", "Accept" => "application/json" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { object: "list", data: [
          { id: "openclaw" },
          { id: "openclaw/default" },
          { id: "openclaw/main" },
          { id: "openclaw/research" }
        ] }.to_json
      )

    models = Assistant::External::ModelCatalog.new(
      url: "https://agent.example.com/v1/chat/completions",
      token: "secret"
    ).models

    assert_requested request
    assert_equal %w[openclaw openclaw/default openclaw/main openclaw/research], models.pluck(:id)
    assert_equal "research (openclaw/research)", models.last[:label]
  end

  test "requires a full chat completions endpoint" do
    catalog = Assistant::External::ModelCatalog.new(url: "https://agent.example.com", token: "secret")

    error = assert_raises(Assistant::External::ModelCatalog::Error) { catalog.models }
    assert_includes error.message, "endpoint must end in /chat/completions"
  end

  test "labels default agents through locale keys" do
    stub_request(:get, "https://agent.example.com/v1/models")
      .to_return(status: 200, body: { data: [ { id: "openclaw" } ] }.to_json)

    models = Assistant::External::ModelCatalog.new(url: "https://agent.example.com/v1/chat/completions", token: "secret").models

    assert_equal I18n.t("assistant.external.model_catalog.default_agent_label", id: "openclaw"), models.first[:label]
    assert_equal "Default agent (openclaw)", models.first[:label]
  end

  test "rejects invalid models response shapes" do
    [
      [ { data: [] } ],
      { data: { id: "openclaw/main" } },
      { data: [ { id: "openclaw/main" }, nil ] },
      { data: [ 1 ] },
      { object: "list" }
    ].each do |body|
      stub_request(:get, "https://agent.example.com/v1/models").to_return(status: 200, body: body.to_json)
      catalog = Assistant::External::ModelCatalog.new(url: "https://agent.example.com/v1/chat/completions", token: "secret")

      error = assert_raises(Assistant::External::ModelCatalog::Error, "expected #{body.inspect} to be rejected") { catalog.models }
      assert_equal "Agent discovery returned an invalid response.", error.message
    end
  end

  test "wraps TLS and low-level connection failures as catalog errors" do
    [ OpenSSL::SSL::SSLError, EOFError, Errno::ETIMEDOUT ].each do |error_class|
      stub_request(:get, "https://agent.example.com/v1/models").to_raise(error_class)
      catalog = Assistant::External::ModelCatalog.new(url: "https://agent.example.com/v1/chat/completions", token: "secret")

      error = assert_raises(Assistant::External::ModelCatalog::Error) { catalog.models }
      assert_includes error.message, "Agent discovery is unavailable"
    end
  end
end
