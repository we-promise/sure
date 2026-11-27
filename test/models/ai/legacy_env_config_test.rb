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
    LLM_MAX_RESPONSE_TOKENS LLM_MAX_ITEMS_PER_CALL ANTHROPIC_MAX_TOKENS JEV_CONCURRENCY
  ].freeze

  # The budget settings take their defaults from the host's LLM_* variables when Setting loads,
  # which `build` clearing ENV can't undo; a test that needs one stubs it again.
  setup { %i[llm_context_window llm_max_response_tokens llm_max_items_per_call].each { Setting.stubs(_1).returns(nil) } }

  def build(env = {})
    with_env_overrides(AI_VARIABLES.index_with { nil }.merge(env)) { Ai::LegacyEnvConfig.build }
  end

  def first_model(config, feature) = config.routes_for(feature).first&.model

  test "an OpenAI key gives the OpenAI preset with today's model, tuning and vector store" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_REQUEST_TIMEOUT" => "90",
                   "OPENAI_EXTRA_HEADERS" => '{"X-Team":"a","X-Session":"{session_id}"}')
    endpoint = config.endpoint(:openai)

    assert_equal :openai, endpoint.preset
    assert_nil endpoint.base_url
    assert_equal :cloud, endpoint.location
    assert endpoint.responses_api
    assert endpoint.vector_store?
    assert_equal 90, endpoint.timeout_seconds
    assert_equal({ "X-Team" => "a" }, endpoint.extra_headers)
    assert_equal "gpt-4.1", first_model(config, :bill_setup).name
    assert first_model(config, :chat).capable?(:tools, :streaming, :structured_output, :vision)
    assert_equal :openai, config.vector_store_backend
    assert_equal Ai::LegacyEnvConfig::VECTOR_STORE_MODEL, first_model(config, :embed).name
  end

  test "a custom Anthropic gateway is trusted with images but not native PDFs" do
    claude = first_model(build("ANTHROPIC_API_KEY" => "sk-ant", "ANTHROPIC_MODEL" => "claude-haiku-4-5",
                               "ANTHROPIC_BASE_URL" => "https://gateway.example.test", "LLM_PROVIDER" => "anthropic"), :extract_pdf)

    assert claude.capable?(:vision)
    assert_not claude.capable?(:documents)
  end

  test "OPENAI_SUPPORTS_PDF_PROCESSING=false keeps PDF import off, as today" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_URI_BASE" => "http://llama:8080/v1",
                   "OPENAI_MODEL" => "qwen3", "OPENAI_SUPPORTS_PDF_PROCESSING" => "false")

    assert_empty config.routes_for(:extract_pdf)
    assert_not first_model(config, :chat).capable?(:vision)
    assert_equal "qwen3", first_model(config, :bill_setup).name, "only PDF import is off"
  end

  test "PDF import ignores the 2,048-token baseline, as today, unless LLM_CONTEXT_WINDOW is set" do
    compatible = { "OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_URI_BASE" => "http://llama:8080/v1", "OPENAI_MODEL" => "qwen3-vl" }
    config = build(compatible)

    assert_nil first_model(config, :extract_pdf).context_window, "pages go in one request, as today"
    assert_equal 2048, first_model(config, :categorize).context_window, "other features keep the baseline"
    assert_equal 8192, first_model(build(compatible.merge("LLM_CONTEXT_WINDOW" => "8192")), :extract_pdf).context_window
  end

  test "in auto, bill setup and PDF import ask a compatible server for json_object, as main did, and the rest keep auto" do
    compatible = { "OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_URI_BASE" => "http://llama:8080/v1", "OPENAI_MODEL" => "qwen3-vl" }
    auto = build(compatible)
    strict = build(compatible.merge("LLM_JSON_MODE" => "strict"))

    assert_equal %i[json_object json_object], %i[bill_setup extract_pdf].map { auto.routes_for(_1).first.effective_json_mode }
    assert_equal %i[auto auto auto], %i[categorize detect_merchants enhance_merchants].map { auto.routes_for(_1).first.effective_json_mode }
    assert_equal %i[strict strict], %i[bill_setup extract_pdf].map { strict.routes_for(_1).first.effective_json_mode },
                 "a JSON mode the operator chose applies to every feature"
  end

  test "an Anthropic install's routes keep the endpoint's JSON mode" do
    config = build("ANTHROPIC_API_KEY" => "sk-ant", "LLM_PROVIDER" => "anthropic")

    assert_nil config.routes_for(:bill_setup).first.json_mode
  end

  # #4836: a regional OpenAI host is native OpenAI — its client uses the Responses API, so its
  # prompt must not be the simplified one written for small local models.
  test "a regional OpenAI host keeps the native endpoint, preset and detailed prompt" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_URI_BASE" => "https://us.api.openai.com", "OPENAI_MODEL" => "gpt-4.1")

    endpoint = config.endpoints.find { _1.protocol == :compatible }
    assert_equal "openai", endpoint.name
    assert_equal :openai, endpoint.preset
    assert endpoint.responses_api
    assert_equal "categorize_transactions", config.routes_for(:categorize).first.prompt
    assert_nil config.routes_for(:categorize).first.model.context_window
  end

  test "a custom OpenAI URL gets no OpenAI vector store" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-or", "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1", "OPENAI_MODEL" => "google/gemma-4-31b-it")

    assert_nil config.vector_store_backend
    assert_empty config.routes_for(:embed)

    VectorStore::Pgvector.stubs(:available?).returns(true)
    named = build("OPENAI_ACCESS_TOKEN" => "sk-or", "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1", "OPENAI_MODEL" => "google/gemma-4-31b-it",
                  "VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => "http://llama.local:8081/v1")
    assert_equal "http://llama.local:8081/v1", first_model(named, :embed).endpoint.base_url
  end

  test "the OpenAI key saved in Settings goes only to the OpenAI URL, not to a separate embedding server" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.openai_access_token = "sk-saved"

    separate = build("VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => "http://embeddings.example.test:11434/v1")
    inherited = build("VECTOR_STORE_PROVIDER" => "pgvector")
    same = build("VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => "https://api.openai.com/v1/")

    assert_nil first_model(separate, :embed).endpoint.api_key
    assert_equal "sk-saved", first_model(inherited, :embed).endpoint.api_key
    assert_equal "sk-saved", first_model(same, :embed).endpoint.api_key, "OpenAI's own URL written out is the same server"
  end

  test "the saved key goes to EMBEDDING_URI_BASE when it is the OpenAI URL saved with it, and nowhere else on that host" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.openai_access_token = "sk-saved"
    Setting.openai_uri_base = "https://gateway.example.test/TenantA/v1"

    same = build("VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => "https://GATEWAY.example.test:443/TenantA/v1/")
    other_tenant = build("VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => "https://gateway.example.test/tenanta/v1")

    assert_equal "sk-saved", first_model(same, :embed).endpoint.api_key
    assert_nil first_model(other_tenant, :embed).endpoint.api_key
  end

  test "EMBEDDING_ACCESS_TOKEN and OPENAI_ACCESS_TOKEN still reach a separate embedding server, as before the router" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.openai_access_token = "sk-saved"
    separate = { "VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => "http://embeddings.example.test:11434/v1" }

    assert_equal "emb-env", first_model(build(separate.merge("EMBEDDING_ACCESS_TOKEN" => "emb-env")), :embed).endpoint.api_key
    assert_equal "sk-env", first_model(build(separate.merge("OPENAI_ACCESS_TOKEN" => "sk-env")), :embed).endpoint.api_key
  end

  test "a self-hosted Jev on https has no calibrated confidence either: only TypeSafe's API does" do
    jev = build("JEV_API_KEY" => "jev-test", "JEV_ENDPOINT" => "https://jev.internal/v1/systemone", "CATEGORIZATION_PROVIDER" => "jev")
            .routes_for(:categorize).first

    assert jev.model.capable?(:judge)
    assert_not jev.model.capable?(:calibrated_confidence)
  end

  test "TypeSafe's API keeps calibrated confidence however its host is cased" do
    jev = build("JEV_API_KEY" => "jev-test", "JEV_ENDPOINT" => "https://API.TypeSafe.ai/v1/systemone", "CATEGORIZATION_PROVIDER" => "jev")
            .routes_for(:categorize).first

    assert jev.model.capable?(:calibrated_confidence)
  end

  test "a misconfigured Jev endpoint is logged once per process, not once per build" do
    Ai::LegacyEnvConfig.unreachably_warned = nil

    assert_difference -> { DebugLogEntry.count }, 1 do
      2.times { build("OPENAI_ACCESS_TOKEN" => "sk-test", "JEV_API_KEY" => "jev-test", "JEV_ENDPOINT" => "https://gw.example.test/key-s3cret/v1/jev") }
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "ai_configuration", entry.category
    assert_equal "error", entry.level
    assert_equal "jev", entry.provider_key
    assert_equal "path", entry.metadata["reason"]
    assert_equal "https://gw.example.test", entry.metadata["endpoint"], "a gateway path can carry a key"
  end

  test "a Jev diagnostic that couldn't be written is tried again on the next build" do
    Ai::LegacyEnvConfig.unreachably_warned = nil
    env = { "OPENAI_ACCESS_TOKEN" => "sk-test", "JEV_API_KEY" => "jev-test", "JEV_ENDPOINT" => "https://gw.example.test/v1/jev" }

    DebugLogEntry.expects(:capture).twice.returns(nil).then.returns(DebugLogEntry.new)
    3.times { build(env) }
  end

  test "an OpenRouter decisions URL derives the /v1 api base for the provider's relative judgments path" do
    jev = Ai::LegacyEnvConfig::Jev

    assert_equal "https://openrouter.ai/api/v1", jev.base_url("https://openrouter.ai/api/alpha/decisions")
    assert_equal "https://openrouter.ai/v1", jev.base_url("https://openrouter.ai/alpha/decisions")
    assert_equal "https://gw.example.test/or/api/v1", jev.base_url("https://gw.example.test/or/api/alpha/decisions")
  end

  test "the Jev host shown to members is never the raw endpoint, which can carry credentials" do
    assert_equal "jev.example.test", Ai::LegacyEnvConfig::Jev.host_for("https://user:secret@jev.example.test/v1/systemone")
    assert_equal Ai::LegacyEnvConfig::Jev::UNREADABLE_HOST, Ai::LegacyEnvConfig::Jev.host_for("https://user:secret@bad host/v1")
    assert_equal Ai::LegacyEnvConfig::Jev::UNREADABLE_HOST, Ai::LegacyEnvConfig::Jev.host_for("user:secret")
  end
  test "OpenAI's own URL, set explicitly, keeps the OpenAI vector store" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_URI_BASE" => "https://api.openai.com/v1")

    assert_equal :openai, config.vector_store_backend
  end
  test "OPENAI_SUPPORTS_PDF_PROCESSING set but empty keeps PDF import off, as it always has" do
    config = build("OPENAI_ACCESS_TOKEN" => "sk-test", "OPENAI_URI_BASE" => "http://llama:8080/v1",
                   "OPENAI_MODEL" => "qwen3", "OPENAI_SUPPORTS_PDF_PROCESSING" => "")

    assert_empty config.routes_for(:extract_pdf)
  end

  test "Anthropic's own URL written out keeps the preset and its PDF limits" do
    config = build("ANTHROPIC_API_KEY" => "sk-ant", "LLM_PROVIDER" => "anthropic", "ANTHROPIC_BASE_URL" => "https://api.anthropic.com")

    assert_equal :anthropic, config.endpoint(:anthropic).preset
    assert config.endpoint(:anthropic).pdf_limits.present?
  end

  test "the default embedding URL with a trailing slash or without is still the server that needs a key" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.stubs(:openai_access_token).returns(nil)   # a host's OPENAI_ACCESS_TOKEN at boot would leak in
    without_slash = VectorStore::DEFAULT_EMBEDDING_URI_BASE.chomp("/")

    config = build("VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => without_slash)

    assert_empty config.routes_for(:embed)
  end

  test "equivalent hosted OpenAI embedding URLs still need a key" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.stubs(:openai_access_token).returns(nil)   # a host's OPENAI_ACCESS_TOKEN at boot would leak in
    config = build("VECTOR_STORE_PROVIDER" => "pgvector",
                   "EMBEDDING_URI_BASE" => "https://API.OPENAI.COM:443/v1/")

    assert_empty config.routes_for(:embed), "a differently spelled api.openai.com is still OpenAI"
  end

  test "an inherited OpenAI URL without a version gets /v1 for embeddings, as for chat; EMBEDDING_URI_BASE stays as written" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.stubs(:openai_access_token).returns("sk-saved")
    Setting.stubs(:openai_uri_base).returns("https://gateway.example/")

    inherited = build("VECTOR_STORE_PROVIDER" => "pgvector")
    written = build("VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_URI_BASE" => "http://ollama:11434")

    assert_equal "https://gateway.example/v1", first_model(inherited, :embed).endpoint.base_url
    assert_equal "sk-saved", first_model(inherited, :embed).endpoint.api_key
    assert_equal "http://ollama:11434", first_model(written, :embed).endpoint.base_url
  end
end
