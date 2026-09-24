require "test_helper"

class Provider::Openai::ModelCatalogTest < ActiveSupport::TestCase
  test "lists models from a custom OpenAI-compatible base URL" do
    request = stub_request(:get, "https://llm.example.com/v1/models")
      .with(headers: { "Authorization" => "Bearer secret", "Accept" => "application/json" })
      .to_return(status: 200, body: { data: [
        { id: "anthropic/claude-sonnet-4.5" },
        { id: "google/gemini-2.5-flash" },
        { id: "anthropic/claude-sonnet-4.5" },
        { id: "" }
      ] }.to_json)

    models = Provider::Openai::ModelCatalog.new(uri_base: "https://llm.example.com/v1/", token: "secret").models

    assert_requested request
    assert_equal %w[anthropic/claude-sonnet-4.5 google/gemini-2.5-flash], models.pluck(:id)
    assert_equal "google/gemini-2.5-flash", models.last[:label]
  end

  test "uses the key-scoped model list on OpenRouter" do
    %w[https://openrouter.ai/api/v1 https://eu.openrouter.ai/api/v1].each do |uri_base|
      request = stub_request(:get, "#{uri_base}/models/user")
        .with(headers: { "Authorization" => "Bearer secret" })
        .to_return(status: 200, body: { data: [ { id: "anthropic/claude-sonnet-4.5" } ] }.to_json)

      models = Provider::Openai::ModelCatalog.new(uri_base: uri_base, token: "secret").models

      assert_requested request
      assert_equal [ "anthropic/claude-sonnet-4.5" ], models.pluck(:id)
    end
  end

  test "defaults to the OpenAI API when no base URL is given" do
    request = stub_request(:get, "https://api.openai.com/v1/models")
      .to_return(status: 200, body: { data: [ { id: "gpt-4.1" } ] }.to_json)

    assert_equal [ "gpt-4.1" ], Provider::Openai::ModelCatalog.new(uri_base: nil, token: "secret").models.pluck(:id)
    assert_requested request
  end

  test "omits the Authorization header when there is no token" do
    stub_request(:get, "http://localhost:11434/v1/models")
      .with { |req| !req.headers.key?("Authorization") }
      .to_return(status: 200, body: { data: [ { id: "llama3.1:8b" } ] }.to_json)

    models = Provider::Openai::ModelCatalog.new(uri_base: "http://localhost:11434/v1", token: nil).models

    assert_equal [ "llama3.1:8b" ], models.pluck(:id)
  end

  test "reports HTTP errors, bad payloads and connection failures as catalog errors" do
    catalog = Provider::Openai::ModelCatalog.new(uri_base: "https://llm.example.com/v1", token: "bad")

    stub_request(:get, "https://llm.example.com/v1/models").to_return(status: 401, body: "{}")
    assert_equal "Model discovery returned HTTP 401.", assert_raises(Provider::Openai::ModelCatalog::Error) { catalog.models }.message

    stub_request(:get, "https://llm.example.com/v1/models").to_return(status: 200, body: { object: "list" }.to_json)
    assert_equal "Model discovery returned an invalid response.", assert_raises(Provider::Openai::ModelCatalog::Error) { catalog.models }.message

    stub_request(:get, "https://llm.example.com/v1/models").to_raise(OpenSSL::SSL::SSLError)
    assert_includes assert_raises(Provider::Openai::ModelCatalog::Error) { catalog.models }.message, "Model discovery is unavailable"
  end

  test "rejects non-HTTP and hostless base URLs as catalog errors" do
    [ "ftp://llm.example.com/v1", "http:/foo", "http:foo", "http:///v1", "https://" ].each do |uri_base|
      error = assert_raises(Provider::Openai::ModelCatalog::Error, "expected #{uri_base.inspect} to be rejected") do
        Provider::Openai::ModelCatalog.new(uri_base: uri_base, token: "secret").models
      end
      assert_includes error.message, I18n.t("provider.openai.model_catalog.errors.invalid_url")
    end
  end

  test "forwards static OPENAI_EXTRA_HEADERS but not session placeholders" do
    extra = { "X-Gateway-Key" => "static-key", "X-Session-Id" => "{session_id}" }.to_json
    request = stub_request(:get, "https://llm.example.com/v1/models")
      .with(headers: { "X-Gateway-Key" => "static-key" }) { |req| !req.headers.key?("X-Session-Id") }
      .to_return(status: 200, body: { data: [ { id: "my-model" } ] }.to_json)

    with_env_overrides("OPENAI_EXTRA_HEADERS" => extra) do
      Provider::Openai::ModelCatalog.new(uri_base: "https://llm.example.com/v1", token: "secret").models
    end

    assert_requested request
  end

  test "error messages come from locale keys" do
    stub_request(:get, "https://llm.example.com/v1/models").to_return(status: 503)

    I18n.with_locale(:en) do
      error = assert_raises(Provider::Openai::ModelCatalog::Error) do
        Provider::Openai::ModelCatalog.new(uri_base: "https://llm.example.com/v1", token: "secret").models
      end
      assert_equal I18n.t("provider.openai.model_catalog.errors.http_status", status: "503"), error.message
    end
  end
end
