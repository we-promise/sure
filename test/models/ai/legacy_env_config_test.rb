require "test_helper"

class Ai::LegacyEnvConfigTest < ActiveSupport::TestCase
  # Cleared in every test, so the host's environment can't leak in.
  AI_VARIABLES = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL OPENAI_REQUEST_TIMEOUT OPENAI_EXTRA_HEADERS
    OPENAI_SUPPORTS_RESPONSES_ENDPOINT OPENAI_SUPPORTS_PDF_PROCESSING ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_REQUEST_TIMEOUT LLM_PROVIDER JEV_API_KEY JEV_ENDPOINT JEV_MODEL
    JEV_REQUEST_TIMEOUT CATEGORIZATION_PROVIDER VECTOR_STORE_PROVIDER EMBEDDING_URI_BASE EMBEDDING_ACCESS_TOKEN
    EMBEDDING_MODEL EMBEDDING_DIMENSIONS EXTERNAL_ASSISTANT_URL EXTERNAL_ASSISTANT_TOKEN EXTERNAL_ASSISTANT_MODEL
    EXTERNAL_ASSISTANT_AGENT_ID EXTERNAL_ASSISTANT_ALLOWED_EMAILS ASSISTANT_TYPE LLM_JSON_MODE LLM_CONTEXT_WINDOW
    LLM_MAX_RESPONSE_TOKENS LLM_MAX_ITEMS_PER_CALL ANTHROPIC_MAX_TOKENS
  ].freeze

  def build(env = {})
    with_env_overrides(AI_VARIABLES.index_with { nil }.merge(env)) { Ai::LegacyEnvConfig.build }
  end

  def first_model(config, feature) = config.routes_for(feature).first&.model

  test "nothing configured gives no endpoints and no routes" do
    config = build

    assert_empty config.endpoints
    assert_empty config.routes
    assert_nil config.vector_store_backend
  end

  test "an OpenAI key gives the OpenAI preset with today's model, tuning and vector store" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_REQUEST_TIMEOUT" => "90",
                   "OPENAI_EXTRA_HEADERS" => '{"X-Team":"a","X-Session":"{session_id}"}')
    endpoint = config.endpoint(:openai)

    assert_equal :openai, endpoint.preset
    assert_nil endpoint.base_url
    assert endpoint.cloud?
    assert endpoint.responses_api
    assert endpoint.vector_store?
    assert_equal 90, endpoint.timeout_seconds
    assert_equal({ "X-Team" => "a" }, endpoint.extra_headers)
    assert_equal "gpt-4.1", first_model(config, :bill_setup).name
    assert first_model(config, :chat).capable?(:tools, :streaming, :structured_output, :vision)
    assert_equal :openai, config.vector_store_backend
    assert_equal Ai::LegacyEnvConfig::VECTOR_STORE_MODEL, first_model(config, :embed).name
  end

  test "a model chat's allow-list refuses can't do tools, but still does structured output" do
    model = first_model(build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_MODEL" => "o4-mini"), :detect_merchants)

    assert model.capable?(:structured_output)
    assert_not model.capable?(:tools)
  end

  test "OPENAI_URI_BASE makes a compatible endpoint, local over http, without the Responses API" do
    config = build("OPENAI_ACCESS_TOKEN" => "ollama", "OPENAI_URI_BASE" => "http://ollama:11434/v1", "OPENAI_MODEL" => "qwen3:8b")
    endpoint = config.endpoint(:openai_compatible)

    assert endpoint.local?
    assert_nil endpoint.preset
    assert_not endpoint.responses_api
    assert_equal "qwen3:8b", first_model(config, :enhance_merchants).name
    assert first_model(config, :chat).capable?(:tools)
  end

  test "a custom URL with no model gets an endpoint but no model or routes, as today's registry builds no client" do
    config = build("OPENAI_ACCESS_TOKEN" => "ollama", "OPENAI_URI_BASE" => "http://ollama:11434/v1")

    assert config.endpoint(:openai_compatible)
    assert_empty config.routes_for(:bill_setup)
    assert_empty config.routes_for(:chat)
  end

  test "values saved in Settings count when ENV is unset" do
    Setting.openai_access_token = "sk-setting"
    Setting.openai_uri_base = "https://gateway.example.test/v1"
    Setting.openai_model = "gpt-4.1-mini"

    config = build
    assert_equal "sk-setting", config.endpoint(:openai_compatible).api_key
    assert_equal "gpt-4.1-mini", first_model(config, :bill_setup).name
  end

  test "LLM_PROVIDER picks the one provider each generation route lists; chat keeps both" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "ANTHROPIC_API_KEY" => "ak-test", "LLM_PROVIDER" => "anthropic")

    %i[bill_setup extract_pdf detect_merchants enhance_merchants categorize].each do |feature|
      assert_equal %w[anthropic], config.routes_for(feature).map { _1.endpoint.name }, feature
    end
    assert_equal %w[anthropic openai], config.routes_for(:chat).map { _1.endpoint.name }
    assert_equal "claude-sonnet-4-6", first_model(config, :bill_setup).name
  end

  test "each generation entry names today's prompt variant" do
    native = build("OPENAI_ACCESS_TOKEN" => "sk-test")
    custom = build("OPENAI_ACCESS_TOKEN" => "x", "OPENAI_URI_BASE" => "http://llm:8080/v1", "OPENAI_MODEL" => "qwen3")
    anthropic = build("ANTHROPIC_API_KEY" => "ak-test")

    assert_equal "categorize_transactions", native.routes_for(:categorize).first.prompt
    assert_equal "categorize_transactions_simple", custom.routes_for(:categorize).first.prompt
    assert_equal "categorize_transactions_anthropic", anthropic.routes_for(:categorize).first.prompt
    assert_equal "detect_merchants_simple", custom.routes_for(:detect_merchants).first.prompt
    assert_equal "enhance_merchants_anthropic", anthropic.routes_for(:enhance_merchants).first.prompt
    assert_equal "bill_setup", custom.routes_for(:bill_setup).first.prompt
    assert_equal "bill_setup_anthropic", anthropic.routes_for(:bill_setup).first.prompt
    assert_nil native.routes_for(:chat).first.prompt
  end

  test "budgets: a custom server's window defaults to 2048; cloud windows only when set" do
    defaults = build("OPENAI_ACCESS_TOKEN" => "sk-test", "ANTHROPIC_API_KEY" => "ak-test")
    openai = defaults.model(:openai, "gpt-4.1")
    anthropic = defaults.model(:anthropic, "claude-sonnet-4-6")
    custom = build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_URI_BASE" => "http://localhost:8080/v1", "OPENAI_MODEL" => "qwen")

    assert_equal 2048, custom.routes_for(:categorize).first.model.context_window
    assert_nil openai.context_window
    assert_nil openai.max_output_tokens
    assert_equal 25, openai.batch_size
    assert_nil anthropic.context_window
    assert_equal 4096, anthropic.max_output_tokens

    tuned = build("OPENAI_ACCESS_TOKEN" => "sk-test", "ANTHROPIC_API_KEY" => "ak-test", "LLM_CONTEXT_WINDOW" => "32768",
                  "LLM_MAX_RESPONSE_TOKENS" => "2048", "LLM_MAX_ITEMS_PER_CALL" => "10", "ANTHROPIC_MAX_TOKENS" => "8192")
    assert_equal [ 32768, 2048, 10 ], tuned.model(:openai, "gpt-4.1").to_h.values_at(:context_window, :max_output_tokens, :batch_size)
    assert_equal [ 32768, 8192, 10 ], tuned.model(:anthropic, "claude-sonnet-4-6").to_h.values_at(:context_window, :max_output_tokens, :batch_size)
  end

  test "batch size prefers ENV, then the setting, then 25" do
    Setting.stubs(:llm_max_items_per_call).returns(40)
    assert_equal 7, build("OPENAI_ACCESS_TOKEN" => "sk-test", "LLM_MAX_ITEMS_PER_CALL" => "7").model(:openai, "gpt-4.1").batch_size
    assert_equal 40, build("OPENAI_ACCESS_TOKEN" => "sk-test").model(:openai, "gpt-4.1").batch_size
  end

  test "the OpenAI endpoint's JSON mode comes from LLM_JSON_MODE, then the setting, then auto" do
    Setting.stubs(:openai_json_mode).returns("json_object")
    assert_equal :none, build("OPENAI_ACCESS_TOKEN" => "sk-test", "LLM_JSON_MODE" => "none").endpoint(:openai).json_mode
    assert_equal :json_object, build("OPENAI_ACCESS_TOKEN" => "sk-test", "LLM_JSON_MODE" => "bogus").endpoint(:openai).json_mode
    Setting.stubs(:openai_json_mode).returns(nil)
    assert_equal :auto, build("OPENAI_ACCESS_TOKEN" => "sk-test").endpoint(:openai).json_mode
  end

  test "Anthropic only defaults the vector store to pgvector when the extension is there" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    config = build("ANTHROPIC_API_KEY" => "ak-test", "LLM_PROVIDER" => "anthropic", "EMBEDDING_URI_BASE" => "http://ollama:11434/v1",
                   "EMBEDDING_MODEL" => "nomic-embed-text", "EMBEDDING_DIMENSIONS" => "768")
    model = first_model(config, :embed)

    assert_equal :pgvector, config.vector_store_backend
    assert_equal "embed", model.endpoint.name
    assert model.endpoint.local?
    assert_equal "nomic-embed-text", model.name
    assert_equal 768, model.embedding_dimensions

    VectorStore::Pgvector.stubs(:available?).returns(false)
    assert_empty build("ANTHROPIC_API_KEY" => "ak-test", "LLM_PROVIDER" => "anthropic").routes_for(:embed)
  end

  test "embeddings fall back to the OpenAI URL and key saved in Settings" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.openai_access_token = "sk-setting"
    Setting.openai_uri_base = "http://llama.local:8080/v1"
    Setting.openai_model = "qwen3"

    endpoint = first_model(build("VECTOR_STORE_PROVIDER" => "pgvector"), :embed).endpoint
    assert_equal "http://llama.local:8080/v1", endpoint.base_url
    assert_equal "sk-setting", endpoint.api_key
  end

  test "Jev is listed first for categorization, for families that chose it, when it can be built" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "JEV_API_KEY" => "jev-test")
    jev = config.routes_for(:categorize).first

    assert_equal "jev", jev.endpoint.name
    assert_equal :jev_family, jev.condition
    assert jev.model.capable?(:judge, :calibrated_confidence)
    assert_equal :jev, jev.endpoint.preset

    assert_empty build("JEV_API_KEY" => "jev-test", "JEV_ENDPOINT" => "http://jev.example.test/v1/systemone").routes_for(:categorize)
  end

  test "the external assistant is an agent endpoint at the end of chat's list" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "EXTERNAL_ASSISTANT_URL" => "https://agent.example.test/v1",
                   "EXTERNAL_ASSISTANT_TOKEN" => "agent-token", "EXTERNAL_ASSISTANT_ALLOWED_EMAILS" => " A@example.com ,b@example.com")
    agent = config.routes_for(:chat).last

    assert agent.agent?
    assert_equal "openclaw/main", agent.model.name
    assert_equal %w[a@example.com b@example.com], agent.endpoint.agent_settings[:allowed_emails]
    assert_not config.routes_for(:bill_setup).any?(&:agent?)
  end
end
