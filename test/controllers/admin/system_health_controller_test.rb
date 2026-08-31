require "test_helper"

class Admin::SystemHealthControllerTest < ActionDispatch::IntegrationTest
  AI_ENVIRONMENT = %w[
    OPENAI_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_MODEL OPENAI_REQUEST_TIMEOUT
    OPENAI_SUPPORTS_PDF_PROCESSING OPENAI_SUPPORTS_RESPONSES_ENDPOINT
    ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_REQUEST_TIMEOUT
    VECTOR_STORE_PROVIDER EMBEDDING_URI_BASE EMBEDDING_MODEL
    EMBEDDING_DIMENSIONS EMBEDDING_ACCESS_TOKEN QDRANT_URL QDRANT_API_KEY
    AI_HEALTH_PROBE_TIMEOUT AI_HEALTH_PROBE_CACHE_TTL
  ].index_with(nil).freeze

  setup do
    Setting.stubs(:llm_provider).returns("openai")
    Setting.stubs(:openai_access_token).returns(nil)
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)
    Setting.stubs(:anthropic_access_token).returns(nil)
    Setting.stubs(:anthropic_base_url).returns(nil)
    Setting.stubs(:anthropic_model).returns(nil)
    AiHealth::Probe.any_instance.stubs(:llm).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:pdf_text_extraction).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:openai_vector_store).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:pgvector).returns(probe_result(:passing))
    AiHealth::Probe.any_instance.stubs(:embedding).returns(probe_result(:passing))
  end

  test "super admin can view the system health page" do
    sign_in users(:sure_support_staff)
    SidekiqHealth.any_instance.stubs(:healthy?).returns(true)
    SidekiqHealth.any_instance.stubs(:processes_count).returns(1)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(Time.current)
    SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
    SidekiqHealth.any_instance.stubs(:enqueued_count).returns(0)
    SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
    SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:processed_count).returns(42)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 0, 0.0 ] ])

    get admin_system_health_url

    assert_response :success
    assert_match(/Sidekiq status/, response.body)
    assert_match(/Healthy/, response.body)
    assert_select "button[role='tab']", text: "AI status"
    assert_select "[data-ds--tabs-navigate-on-change-value='true']"
  end

  test "renders degraded state with reason when Sidekiq is unhealthy" do
    sign_in users(:sure_support_staff)
    SidekiqHealth.any_instance.stubs(:healthy?).returns(false)
    SidekiqHealth.any_instance.stubs(:reason).returns(:no_worker_processes)
    SidekiqHealth.any_instance.stubs(:processes_count).returns(0)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(nil)
    SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
    SidekiqHealth.any_instance.stubs(:enqueued_count).returns(7)
    SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
    SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:processed_count).returns(0)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([])

    get admin_system_health_url

    assert_response :success
    assert_match(/Degraded/, response.body)
    assert_match(/No Sidekiq worker process is connected/, response.body)
  end

  test "non super admin is redirected away" do
    sign_in users(:family_admin)

    get admin_system_health_url

    assert_redirected_to root_path
  end

  test "unauthenticated user is redirected to sign in" do
    get admin_system_health_url

    assert_redirected_to new_session_path
  end

  test "AI status reports the default OpenAI LLM and hosted vector store" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_select "button[role='tab'][aria-selected='true']", text: "AI status"
    assert_match(/LLM and PDF processing/, response.body)
    assert_select "[data-testid='selected-llm-provider']", text: "OpenAI"
    assert_select "[data-testid='effective-llm-provider']", text: "OpenAI"
    assert_match(/gpt-4\.1/, response.body)
    assert_match(%r{https://api\.openai\.com/v1}, response.body)
    assert_match(/OpenAI hosted vector store/, response.body)
    assert_match(/Live check passed/, response.body)
    assert_match(/Live checks passed/, response.body)
    assert_match(/PDF text-extraction path/, response.body)
    assert_match(/PDF vision\/native path/, response.body)
    assert_equal 2, response.body.scan(/Synthetic PDF check passed/).size
    assert_no_match(/sk-secret-openai/, response.body)
  end

  test "background jobs tab does not run AI probes" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.expects(:llm).never
    AiHealth::Probe.any_instance.expects(:function_calling).never
    AiHealth::Probe.any_instance.expects(:pdf_text_extraction).never
    AiHealth::Probe.any_instance.expects(:pdf_vision_processing).never
    AiHealth::Probe.any_instance.expects(:openai_vector_store).never

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get admin_system_health_url
    end

    assert_response :success
    assert_match(/Not checked/, response.body)
    assert_no_match(/sk-secret-openai/, response.body)
  end

  test "AI status warns when a custom OpenAI endpoint is paired with the hosted vector store" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "local-token",
      "OPENAI_URI_BASE" => credentialed_url(
        scheme: "http",
        host: "ollama",
        port: 11_434,
        path: "/v1",
        user: "operator",
        password: "uri-secret",
        query: "api_key=query-secret"
      ),
      "OPENAI_MODEL" => "qwen3:8b"
    ) do
      AiHealth::Probe.any_instance.stubs(:openai_vector_store).returns(
        probe_result(:failing, failure_code: :request_failed, http_status: 404)
      )
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_select "[data-testid='selected-llm-provider']", text: "OpenAI-compatible"
    assert_select "[data-testid='effective-llm-provider']", text: "Ollama"
    assert_match(/OpenAI-compatible API credentials/, response.body)
    assert_match(%r{http://ollama:11434/v1}, response.body)
    assert_match(%r{did not pass the /v1/vector_stores liveness check}, response.body)
    assert_match(/use pgvector with a separate embeddings endpoint/, response.body)
    assert_match(/Live check failed/, response.body)
    assert_no_match(/local-token|uri-secret|query-secret/, response.body)
  end

  test "AI status names the missing function-calling support behind an unhelpful chat error" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(
      probe_result(:failing, failure_code: :tools_refused, http_status: 404)
    )

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "router-secret",
      "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1",
      "OPENAI_MODEL" => "tngtech/deepseek-r1t2-chimera:free"
    ) do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_select "[data-testid='function-calling-status']", text: /Not supported by the effective provider/
    assert_match(/The model does not support function calling/, response.body)
    assert_match(/Function-calling failure reason/, response.body)
    assert_no_match(/router-secret/, response.body)
  end

  test "AI status separates a model that ignores tools from one that cannot use them" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(
      probe_result(:failing, failure_code: :no_tool_call)
    )

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_select "[data-testid='function-calling-status']", text: /Tools accepted, but the model called none/
    assert_match(/answered without calling the tool it was asked to call/, response.body)
    assert_no_match(/The model does not support function calling/, response.body)
  end

  test "AI status reports text and vision PDF probes separately" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(
      probe_result(:failing, failure_code: :invalid_response)
    )

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_match(/PDF text-extraction path/, response.body)
    assert_match(/PDF vision\/native path/, response.body)
    assert_match(/The synthetic PDF vision\/native check failed/, response.body)
    assert_match(/Synthetic PDF check passed/, response.body)
    assert_match(/Synthetic PDF check failed/, response.body)
    assert_match(/Vision\/native failure reason/, response.body)
    assert_match(/unexpected response/, response.body)
    assert_no_match(/sk-secret-openai/, response.body)
  end

  test "AI status surfaces LLM and probe request timeouts as distinct values" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    # OPENAI_REQUEST_TIMEOUT bounds real LLM calls the app makes (chat, PDF
    # import). AI_HEALTH_PROBE_TIMEOUT only bounds the admin "live checks".
    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "local-token",
      "OPENAI_REQUEST_TIMEOUT" => "300",
      "AI_HEALTH_PROBE_TIMEOUT" => "5"
    ) do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    llm_label = response.body.index("LLM request timeout")
    probe_label = response.body.index("Health-check probe timeout")
    assert llm_label, "expected an 'LLM request timeout' label on the AI status page"
    assert probe_label, "expected a 'Health-check probe timeout' label on the AI status page"
    assert_operator llm_label, :<, probe_label, "LLM timeout row should appear before the probe timeout row"
    assert response.body[llm_label, 400].include?("300s"), "LLM timeout value (300s) missing near its label"
    assert response.body[probe_label, 400].include?("5s"), "probe timeout value (5s) missing near its label"
    assert_no_match(/local-token/, response.body)
  end

  test "AI status does not probe PDF processing when it is explicitly disabled" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.expects(:pdf_text_extraction).never
    AiHealth::Probe.any_instance.expects(:pdf_vision_processing).never

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "sk-secret-openai",
      "OPENAI_SUPPORTS_PDF_PROCESSING" => "false"
    ) do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_match(/Disabled or not supported by the effective provider\/model/, response.body)
    assert_no_match(/The synthetic PDF .* check failed/, response.body)
  end

  test "AI status reports Anthropic with an available pgvector store" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    Setting.stubs(:llm_provider).returns("anthropic")

    connection = stub("connection")
    connection.stubs(:table_exists?).with(VectorStore::Pgvector::TABLE_NAME).returns(true)
    connection.stubs(:extension_enabled?).with("vector").returns(true)
    ActiveRecord::Base.stubs(:connection).returns(connection)
    VectorStore.expects(:embedding_access_token).returns("runtime-embedding-token")
    AiHealth::Probe.any_instance.expects(:embedding).with(
      endpoint: "http://ollama:11434/v1",
      access_token: "runtime-embedding-token",
      model: "mxbai-embed-large",
      dimensions: 1024
    ).returns(probe_result(:passing))

    with_ai_environment(
      "ANTHROPIC_ACCESS_TOKEN" => "anthropic-secret",
      "ANTHROPIC_MODEL" => "claude-sonnet-4-6",
      "EMBEDDING_URI_BASE" => "http://ollama:11434/v1",
      "EMBEDDING_MODEL" => "mxbai-embed-large",
      "EMBEDDING_DIMENSIONS" => "1024"
    ) do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_match(/Anthropic/, response.body)
    assert_match(/pgvector/, response.body)
    assert_match(/PostgreSQL vector extension/, response.body)
    assert_match(/mxbai-embed-large/, response.body)
    assert_match(%r{http://ollama:11434/v1}, response.body)
    assert_match(/Live checks passed/, response.body)
    assert_no_match(/anthropic-secret/, response.body)
  end

  test "AI status explains when no vector store is configured" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    with_ai_environment do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_match(/No vector store is configured/, response.body)
    assert_match(/Uploaded documents cannot be indexed or searched/, response.body)
  end

  test "AI status marks Qdrant as scaffolded and redacts its URL" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    with_ai_environment(
      "VECTOR_STORE_PROVIDER" => "qdrant",
      "QDRANT_URL" => credentialed_url(
        scheme: "https",
        host: "qdrant.example.test",
        port: 6333,
        user: "admin",
        password: "qdrant-secret",
        query: "api_key=query-secret"
      ),
      "QDRANT_API_KEY" => "header-secret"
    ) do
      get admin_system_health_url(tab: "ai")
    end

    assert_response :success
    assert_match(/Qdrant support is not implemented yet/, response.body)
    assert_match(/Scaffolded/, response.body)
    assert_match(%r{https://qdrant\.example\.test:6333}, response.body)
    assert_no_match(/qdrant-secret|query-secret|header-secret/, response.body)
  end

  private
    def credentialed_url(scheme:, host:, port:, user:, password:, path: nil, query: nil)
      URI::Generic.build(
        scheme: scheme,
        userinfo: "#{user}:#{password}",
        host: host,
        port: port,
        path: path,
        query: query
      ).to_s
    end

    def probe_result(status, failure_code: nil, http_status: nil)
      AiHealth::Probe::Result.new(
        status: status,
        checked_at: status.in?([ :passing, :failing ]) ? Time.current : nil,
        failure_code: failure_code,
        http_status: http_status
      )
    end

    def with_ai_environment(overrides = {}, &block)
      ClimateControl.modify(AI_ENVIRONMENT.merge(overrides), &block)
    end

    def stub_healthy_sidekiq
      SidekiqHealth.any_instance.stubs(:healthy?).returns(true)
      SidekiqHealth.any_instance.stubs(:processes_count).returns(1)
      SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(Time.current)
      SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
      SidekiqHealth.any_instance.stubs(:enqueued_count).returns(0)
      SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
      SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
      SidekiqHealth.any_instance.stubs(:processed_count).returns(42)
      SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 0, 0.0 ] ])
    end
end
