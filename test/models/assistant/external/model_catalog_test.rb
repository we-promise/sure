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
end
