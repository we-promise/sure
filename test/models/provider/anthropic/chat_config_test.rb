require "test_helper"

class Provider::Anthropic::ChatConfigTest < ActiveSupport::TestCase
  test "builds request with default max_tokens and prompt message" do
    config = Provider::Anthropic::ChatConfig.new(prompt: "hello")

    req = config.build_request(model: "claude-sonnet-4-6")

    assert_equal "claude-sonnet-4-6", req[:model]
    assert_equal 4096, req[:max_tokens]
    assert_equal [ { role: "user", content: "hello" } ], req[:messages]
    assert_nil req[:system_]
    assert_nil req[:tools]
  end

  test "honors caller-provided default_max_tokens" do
    config = Provider::Anthropic::ChatConfig.new(prompt: "hi", default_max_tokens: 8192)

    req = config.build_request(model: "claude-sonnet-4-6")

    assert_equal 8192, req[:max_tokens]
  end

  test "wraps instructions as cacheable system block" do
    config = Provider::Anthropic::ChatConfig.new(prompt: "hi", instructions: "Be terse.")

    req = config.build_request(model: "claude-sonnet-4-6")

    assert_equal [ {
      type: "text",
      text: "Be terse.",
      cache_control: { type: "ephemeral" }
    } ], req[:system_]
  end

  test "converts function definitions to Anthropic tool blocks and caches the last one" do
    config = Provider::Anthropic::ChatConfig.new(
      prompt: "hi",
      functions: [
        {
          name: "get_net_worth",
          description: "Returns net worth",
          params_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
          strict: true
        },
        {
          name: "get_accounts",
          description: "Returns accounts",
          params_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
          strict: true
        }
      ]
    )

    req = config.build_request(model: "claude-sonnet-4-6")

    assert_equal 2, req[:tools].size
    assert_equal "get_net_worth", req[:tools][0][:name]
    assert_equal "Returns net worth", req[:tools][0][:description]
    assert_equal({ type: "object", properties: {}, required: [], additionalProperties: false }, req[:tools][0][:input_schema])
    assert_nil req[:tools][0][:cache_control]

    assert_equal({ type: "ephemeral" }, req[:tools][1][:cache_control])

    # Anthropic schemas must not carry the OpenAI-specific `strict` flag.
    req[:tools].each { |t| assert_not t[:input_schema].key?(:strict) }
  end

  test "strips both symbol and string-keyed `strict` flags from input_schema" do
    config = Provider::Anthropic::ChatConfig.new(
      prompt: "hi",
      functions: [
        {
          name: "fn_with_string_strict",
          description: "schema arrived from JSON.parse with string keys",
          params_schema: {
            "type" => "object",
            "properties" => {},
            "required" => [],
            "additionalProperties" => false,
            "strict" => true
          },
          strict: true
        }
      ]
    )

    req = config.build_request(model: "claude-sonnet-4-6")

    schema = req[:tools].first[:input_schema]
    assert_not schema.key?(:strict)
    assert_not schema.key?("strict")
  end
end
