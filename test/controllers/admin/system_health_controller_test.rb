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
    # Nothing in the queue table takes focus, so on a narrow screen the scroll
    # area has to be a named tab stop of its own for a keyboard to scroll it.
    assert_select "[role='region'][aria-label='Queues']"
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

  test "German background job translations are present without fallback" do
    keys = %w[
      title tabs.background_jobs tabs.ai tabs.configuration alert.title
      status_section_title status_section_description counters_section_title
      counters_section_description queues_section_title queues_section_description
      labels.status labels.processes labels.last_heartbeat labels.max_queue_latency
      labels.enqueued labels.retries labels.failed labels.processed_total
      labels.queue labels.size labels.latency values.healthy values.unhealthy
      values.never values.no_queues
    ]
    keys.each do |key|
      assert_kind_of String, I18n.t("admin.system_health.show.#{key}", locale: :de, fallback: false, raise: true)
    end
    assert_equal "vor 2 Minuten", I18n.t("admin.system_health.show.values.time_ago", locale: :de,
      fallback: false, raise: true, time_ago: "2 Minuten")
    assert_equal "1,5 s", I18n.t("admin.system_health.show.values.seconds", locale: :de,
      fallback: false, raise: true, seconds: "1,5")
  end

  test "German super admin sees localized background job statistics" do
    users(:sure_support_staff).update!(locale: "de")
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    travel_to Time.current do
      SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(2.minutes.ago)
      SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([ [ "default", 1234, 1.5 ] ])
      get admin_system_health_url
    end

    assert_response :success
    assert_select "h1", text: "Systemstatus"
    assert_select "button[role='tab'][aria-selected='true']", text: "Hintergrundaufgaben"
    assert_select "button[role='tab']", text: "KI-Status"
    assert_select "h2", text: "Sidekiq-Status"
    assert_select "h2", text: "Aufgabenstatistik"
    assert_select "h2", text: "Warteschlangen"
    assert_select "dd", text: "Funktionsfähig"
    assert_select "dd", text: "vor 2 Minuten"
    {
      "Status" => "Funktionsfähig", "Worker-Prozesse" => "1",
      "Letztes Lebenszeichen" => "vor 2 Minuten", "Längste Wartezeit" => "0,0 s",
      "In der Warteschlange" => "0", "Zur Wiederholung vorgemerkt" => "0",
      "Fehlgeschlagen" => "0", "Insgesamt verarbeitet" => "42"
    }.each do |label, value|
      assert_select "dl > div" do |items|
        item = items.find { |element| element.at_css("dt")&.text == label }
        assert item, "Missing statistic: #{label}"
        assert_equal value, item.at_css("dd").text.strip
      end
    end
    assert_select "th", text: "Anzahl der Aufgaben"
    assert_select "th", text: "Wartezeit"
    assert_select "td", text: "default"
    assert_select "td", text: "1.234"
    assert_select "td", text: "1,5 s"
  end

  test "German background job statistics show degraded and empty states" do
    users(:sure_support_staff).update!(locale: "de")
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    SidekiqHealth.any_instance.stubs(:healthy?).returns(false)
    SidekiqHealth.any_instance.stubs(:reason).returns(:no_worker_processes)
    SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(nil)
    SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([])

    get admin_system_health_url

    assert_response :success
    assert_select "dd", text: "Beeinträchtigt"
    assert_select "dd", text: "Nie"
    assert_match "Hintergrundaufgaben werden nicht ausgeführt", response.body
    assert_select "p", text: "Es sind keine Warteschlangen registriert. Möglicherweise läuft der Worker nicht."
  end

  test "non super admin is redirected away" do
    users(:family_admin).update!(locale: "de")
    sign_in users(:family_admin)

    get admin_system_health_url

    assert_redirected_to root_path
  end

  test "unauthenticated user is redirected to sign in" do
    get admin_system_health_url

    assert_redirected_to new_session_path
  end

  test "only super admins can run the AI checks" do
    AiHealth::Probe.any_instance.expects(:llm).never

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
      assert_redirected_to new_session_path

      sign_in users(:family_admin)
      get ai_status_admin_system_health_url
      assert_redirected_to root_path
    end
  end

  test "AI status reports the default OpenAI LLM and hosted vector store" do
    sign_in users(:sure_support_staff)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "turbo-frame#ai_status"
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

  test "the page leaves the AI probes to a lazy frame on either tab" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    AiHealth::Probe.any_instance.expects(:llm).never
    AiHealth::Probe.any_instance.expects(:function_calling).never
    AiHealth::Probe.any_instance.expects(:pdf_text_extraction).never
    AiHealth::Probe.any_instance.expects(:pdf_vision_processing).never
    AiHealth::Probe.any_instance.expects(:openai_vector_store).never

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      { "background_jobs" => "Background jobs", "ai" => "AI status", "configuration" => "Configuration" }.each do |tab, label|
        get admin_system_health_url(tab: tab)

        assert_response :success
        assert_select "button[role='tab'][aria-selected='true']", text: label
        assert_select "turbo-frame#ai_status[loading='lazy'][src='#{ai_status_admin_system_health_path}']",
          text: "Running live checks…"
      end
    end
  end

  test "the lazy frame keeps the page's refresh and locale override" do
    sign_in users(:sure_support_staff)

    get admin_system_health_url(tab: "ai", refresh_ai_health: "1", locale: "de")

    assert_select "turbo-frame#ai_status[src='#{ai_status_admin_system_health_path(refresh_ai_health: "1", locale: "de")}']"
  end

  test "the lazy frame drops a refresh or locale it can't use" do
    sign_in users(:sure_support_staff)

    [ { refresh_ai_health: "0", locale: "xx" }, { refresh_ai_health: { "x" => "1" }, locale: { "x" => "de" } } ].each do |query|
      get admin_system_health_url(tab: "ai", **query)

      assert_response :success
      assert_select "turbo-frame#ai_status[src='#{ai_status_admin_system_health_path}']"
    end
  end

  # The redirect's morph reloads the frame from its old src, so an override
  # dropped on the way would leave the page and the frame in two languages.
  test "a locale override survives the worker check round trip" do
    sign_in users(:sure_support_staff)

    with_ai_environment do
      get ai_status_admin_system_health_url(locale: "de")
    end
    assert_select "form[action=?]", verify_worker_ai_admin_system_health_path(locale: "de")

    post verify_worker_ai_admin_system_health_url(locale: "de")
    assert_redirected_to admin_system_health_path(tab: "ai", locale: "de")
  end

  test "AI status warns when a custom OpenAI endpoint is paired with the hosted vector store" do
    sign_in users(:sure_support_staff)

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
      get ai_status_admin_system_health_url
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
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(
      probe_result(:failing, failure_code: :tools_refused, http_status: 404)
    )

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "router-secret",
      "OPENAI_URI_BASE" => "https://openrouter.ai/api/v1",
      "OPENAI_MODEL" => "tngtech/deepseek-r1t2-chimera:free"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "[data-testid='function-calling-status']", text: /Not supported by the effective provider/
    assert_match(/The model does not support function calling/, response.body)
    assert_match(/Function-calling failure reason/, response.body)
    assert_no_match(/router-secret/, response.body)
  end

  test "AI status names an unavailable configured LLM model" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.stubs(:llm).returns(
      probe_result(:failing, failure_code: :model_not_available)
    )

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "gemini-secret",
      "OPENAI_URI_BASE" => "https://generativelanguage.googleapis.com/v1beta/openai",
      "OPENAI_MODEL" => "retired-gemini-model"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/The configured AI model is not available/, response.body)
    assert_match(/gemini-3\.8-flash/, response.body)
    assert_no_match(/gemini-secret/, response.body)
  end

  test "AI status separates a model that ignores tools from one that cannot use them" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.stubs(:function_calling).returns(
      probe_result(:failing, failure_code: :no_tool_call)
    )

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "[data-testid='function-calling-status']", text: /Tools accepted, but the model called none/
    assert_match(/answered without calling the tool it was asked to call/, response.body)
    assert_no_match(/The model does not support function calling/, response.body)
  end

  test "AI status reports text and vision PDF probes separately" do
    sign_in users(:sure_support_staff)
    AiHealth::Probe.any_instance.stubs(:pdf_vision_processing).returns(
      probe_result(:failing, failure_code: :invalid_response)
    )

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
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

    # OPENAI_REQUEST_TIMEOUT bounds real LLM calls the app makes (chat, PDF
    # import). AI_HEALTH_PROBE_TIMEOUT only bounds the admin "live checks".
    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "local-token",
      "OPENAI_REQUEST_TIMEOUT" => "300",
      "AI_HEALTH_PROBE_TIMEOUT" => "5"
    ) do
      get ai_status_admin_system_health_url
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
    AiHealth::Probe.any_instance.expects(:pdf_text_extraction).never
    AiHealth::Probe.any_instance.expects(:pdf_vision_processing).never

    with_ai_environment(
      "OPENAI_ACCESS_TOKEN" => "sk-secret-openai",
      "OPENAI_SUPPORTS_PDF_PROCESSING" => "false"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/Disabled or not supported by the effective provider\/model/, response.body)
    assert_no_match(/The synthetic PDF .* check failed/, response.body)
  end

  test "AI status reports Anthropic with an available pgvector store" do
    sign_in users(:sure_support_staff)
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
      get ai_status_admin_system_health_url
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

  test "AI status explains a missing pgvector table" do
    sign_in users(:sure_support_staff)
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Pgvector.stubs(:available?).returns(true)
    AiHealth::Probe.any_instance.stubs(:pgvector).returns(
      probe_result(:failing, failure_code: :table_not_found)
    )

    connection = stub("connection")
    connection.stubs(:table_exists?).with(VectorStore::Pgvector::TABLE_NAME).returns(false)
    connection.stubs(:extension_enabled?).with("vector").returns(true)
    ActiveRecord::Base.stubs(:connection).returns(connection)

    with_ai_environment(
      "ANTHROPIC_ACCESS_TOKEN" => "anthropic-secret",
      "ANTHROPIC_MODEL" => "claude-sonnet-4-6",
      "EMBEDDING_URI_BASE" => "http://ollama:11434/v1",
      "EMBEDDING_MODEL" => "mxbai-embed-large",
      "EMBEDDING_DIMENSIONS" => "1024"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/The vector_store_chunks table is missing/, response.body)
    assert_match(/VECTOR_STORE_PROVIDER=pgvector/, response.body)
    assert_match(/table was not found/, response.body)
    assert_no_match(/anthropic-secret/, response.body)
  end

  test "AI status explains an embedding dimensions mismatch" do
    sign_in users(:sure_support_staff)
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Pgvector.stubs(:available?).returns(true)
    AiHealth::Probe.any_instance.stubs(:embedding).returns(
      probe_result(:failing, failure_code: :dimensions_mismatch)
    )

    connection = stub("connection")
    connection.stubs(:table_exists?).with(VectorStore::Pgvector::TABLE_NAME).returns(true)
    connection.stubs(:extension_enabled?).with("vector").returns(true)
    ActiveRecord::Base.stubs(:connection).returns(connection)

    with_ai_environment(
      "ANTHROPIC_ACCESS_TOKEN" => "anthropic-secret",
      "ANTHROPIC_MODEL" => "claude-sonnet-4-6",
      "EMBEDDING_URI_BASE" => "https://generativelanguage.googleapis.com/v1beta/openai",
      "EMBEDDING_MODEL" => "gemini-embedding-2-preview",
      "EMBEDDING_DIMENSIONS" => "1024"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/The embedding dimensions do not match/, response.body)
    assert_match(/EMBEDDING_MODEL and EMBEDDING_DIMENSIONS/, response.body)
    assert_match(/alter or recreate the pgvector embedding column\/table/, response.body)
    assert_match(/gemini-embedding-2-preview/, response.body)
    assert_no_match(/anthropic-secret/, response.body)
  end

  test "AI status explains embedding probe timeouts" do
    sign_in users(:sure_support_staff)
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Pgvector.stubs(:available?).returns(true)
    AiHealth::Probe.any_instance.stubs(:embedding).returns(
      probe_result(:failing, failure_code: :timeout)
    )

    connection = stub("connection")
    connection.stubs(:table_exists?).with(VectorStore::Pgvector::TABLE_NAME).returns(true)
    connection.stubs(:extension_enabled?).with("vector").returns(true)
    ActiveRecord::Base.stubs(:connection).returns(connection)

    with_ai_environment(
      "ANTHROPIC_ACCESS_TOKEN" => "anthropic-secret",
      "ANTHROPIC_MODEL" => "claude-sonnet-4-6",
      "EMBEDDING_URI_BASE" => "https://generativelanguage.googleapis.com/v1beta/openai",
      "EMBEDDING_MODEL" => "gemini-embedding-2-preview",
      "EMBEDDING_DIMENSIONS" => "3072"
    ) do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/The embedding live check timed out/, response.body)
    assert_match(/AI_HEALTH_PROBE_TIMEOUT/, response.body)
    assert_match(/OPENAI_REQUEST_TIMEOUT/, response.body)
    assert_no_match(/anthropic-secret/, response.body)
  end

  test "AI status explains when no vector store is configured" do
    sign_in users(:sure_support_staff)

    with_ai_environment do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/No vector store is configured/, response.body)
    assert_match(/Uploaded documents cannot be indexed or searched/, response.body)
  end

  test "AI status marks Qdrant as scaffolded and redacts its URL" do
    sign_in users(:sure_support_staff)

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
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/Qdrant support is not implemented yet/, response.body)
    assert_match(/Scaffolded/, response.body)
    assert_match(%r{https://qdrant\.example\.test:6333}, response.body)
    assert_no_match(/qdrant-secret|query-secret|header-secret/, response.body)
  end

  test "AI status keeps its standing guidance collapsed" do
    sign_in users(:sure_support_staff)

    with_ai_environment do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_select "details:not([open]) summary", text: "Which settings need a restart?"
    assert_select "details:not([open]) summary", text: "Recommended local setup"
  end

  test "AI status explains when no worker has checked in yet" do
    sign_in users(:sure_support_staff)

    with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
      get ai_status_admin_system_health_url
    end

    assert_response :success
    assert_match(/Worker verification/, response.body)
    assert_match(/No worker has checked in yet/, response.body)
  end

  test "AI status renders a worker result and flags it matching the web configuration" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          effective_provider: :openai,
          llm_model: "gpt-4.1",
          llm_endpoint: "https://api.openai.com/v1",
          vector_store_adapter: :openai
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_select "[data-testid='worker-process-identity']", text: "worker-1:123"
    assert_match(/Matches web/, response.body)
    assert_no_match(/sk-secret-openai/, response.body)
  end

  test "AI status flags a worker result whose configuration differs from the web process" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          effective_provider: :openai,
          llm_model: "a-different-model-than-web-resolves",
          llm_endpoint: "https://api.openai.com/v1"
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_match(/Differs from web/, response.body)
  end

  test "AI status shows a failing worker result with its failure reason" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          llm_status: :failing,
          failure_codes: [ :model_not_available ]
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_match(/The configured model was not returned by the provider/, response.body)
  end

  test "German AI failure reasons are present without fallback and render in worker results" do
    reasons = {
      model_not_available: "Das konfigurierte Modell wurde vom Anbieter nicht zurückgegeben",
      no_tool_call: "Das Modell hat geantwortet, ohne das Prüfwerkzeug aufzurufen",
      tools_refused: "Der Dienst hat dieselbe Anfrage ohne Werkzeuge beantwortet, sie mit Werkzeugen jedoch abgelehnt",
      invalid_response: "Der Dienst hat eine unerwartete Antwort zurückgegeben",
      dimensions_mismatch: "Die Dimensionen des Embedding-Vektors stimmen nicht mit den konfigurierten Dimensionen überein",
      extension_not_enabled: "Die PostgreSQL-Erweiterung vector ist nicht aktiviert",
      table_not_found: "Die Tabelle vector_store_chunks wurde nicht gefunden",
      render_missing_binary: "Der Renderer pdftoppm (poppler-utils) ist in diesem Container nicht verfügbar",
      timeout: "Der Dienst hat nicht innerhalb des Zeitlimits für die Prüfung geantwortet",
      request_failed: "Die Anfrage an den Dienst ist fehlgeschlagen",
      unsupported_provider: "Der Anbieter unterstützt diese Prüfung nicht"
    }
    reasons.each do |code, text|
      assert_equal text, I18n.t("admin.system_health.show.ai.failure_codes.#{code}", locale: :de, fallback: false, raise: true)
    end
    {
      failure_reason: "Fehlerursache",
      function_calling_failure_reason: "Fehlerursache beim Funktionsaufruf",
      pdf_text_extraction_failure_reason: "Fehlerursache bei der Textextraktion",
      pdf_vision_processing_failure_reason: "Fehlerursache bei der Bildverarbeitung oder nativen Dokumentverarbeitung"
    }.each do |key, text|
      assert_equal text, I18n.t("admin.system_health.show.ai.labels.#{key}", locale: :de, fallback: false, raise: true)
    end

    sign_in users(:sure_support_staff)
    with_memory_cache do
      with_ai_environment do
        WorkerAiHealth.record!(worker_snapshot(llm_status: :failing, failure_codes: reasons.keys))
        get ai_status_admin_system_health_url(locale: :de)
      end
    end

    assert_response :success
    assert_select "dt", text: "Fehlerursache"
    reasons.each_value { |text| assert_select "dd", text: /#{Regexp.escape(text)}/ }
  end

  test "AI status shows a stale worker result as stale rather than passing" do
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "sk-secret-openai") do
        WorkerAiHealth.record!(worker_snapshot(
          process_identity: "worker-1:123",
          checked_at: (WorkerAiHealth::STALE_AFTER + 1.minute).ago
        ))

        get ai_status_admin_system_health_url
      end
    end

    assert_response :success
    assert_match(/Stale/, response.body)
  end

  test "verify_worker_ai queues an asynchronous worker check and redirects to the AI tab" do
    sign_in users(:sure_support_staff)

    assert_enqueued_with(job: WorkerAiHealthCheckJob) do
      post verify_worker_ai_admin_system_health_url
    end

    assert_redirected_to admin_system_health_path(tab: "ai")
    follow_redirect!
    assert_match(/Worker check queued/, response.body)
  end

  test "non super admin cannot queue a worker check" do
    sign_in users(:family_admin)

    assert_no_enqueued_jobs only: WorkerAiHealthCheckJob do
      post verify_worker_ai_admin_system_health_url
    end

    assert_redirected_to root_path
  end

  test "unauthenticated user cannot queue a worker check" do
    assert_no_enqueued_jobs only: WorkerAiHealthCheckJob do
      post verify_worker_ai_admin_system_health_url
    end

    assert_redirected_to new_session_path
  end

  test "German worker verification copy is present without fallback" do
    keys = %w[
      title description verify_button coverage_notice empty.title empty.description
      labels.process labels.checked_at labels.configuration
      configuration_statuses.match configuration_statuses.mismatch
      statuses.passing statuses.failing statuses.stale
      settings_origin.title settings_origin.database_backed settings_origin.env_backed
    ]
    keys.each do |key|
      assert_kind_of String, I18n.t("admin.system_health.show.ai.worker.#{key}", locale: :de, fallback: false, raise: true)
    end
    assert_kind_of String, I18n.t("admin.system_health.verify_worker_ai.queued", locale: :de, fallback: false, raise: true)
  end

  test "German super admin sees worker verification guidance and queued notice" do
    users(:sure_support_staff).update!(locale: "de")
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq

    with_memory_cache do
      with_ai_environment do
        get ai_status_admin_system_health_url
        assert_response :success
        assert_select "h2", text: "Worker-Verifikation"
        assert_select "button", text: "Worker-Konfiguration prüfen"
        assert_match(/Bisher hat kein Worker ein Prüfergebnis gemeldet/, response.body)
        assert_match(/Jede Prüfung erfasst genau einen Worker-Prozess/, response.body)
        assert_match(/Welche Einstellungen erfordern einen Neustart\?/, response.body)
        assert_match(/kein Neustart erforderlich/, response.body)
        assert_match(/sowohl der Web- als auch der Worker-Dienst/, response.body)

        assert_enqueued_with(job: WorkerAiHealthCheckJob) do
          post verify_worker_ai_admin_system_health_url
        end
        assert_redirected_to admin_system_health_path(tab: "ai")
        follow_redirect!
        assert_match(/Die Worker-Prüfung wurde in die Warteschlange gestellt/, response.body)
      end
    end
  end

  test "German worker results distinguish passing failing stale and differing configurations" do
    users(:sure_support_staff).update!(locale: "de")
    sign_in users(:sure_support_staff)

    with_memory_cache do
      with_ai_environment("OPENAI_ACCESS_TOKEN" => "synthetic-token") do
        [
          [ {}, "Erfolgreich", "Entspricht dem Web-Prozess" ],
          [ { llm_status: :failing, llm_model: "different-model" }, "Fehlgeschlagen", "Weicht vom Web-Prozess ab" ],
          [ { checked_at: (WorkerAiHealth::STALE_AFTER + 1.minute).ago }, "Veraltet", "Entspricht dem Web-Prozess" ]
        ].each do |overrides, status, configuration|
          WorkerAiHealth.record!(worker_snapshot(**{ vector_store_adapter: :openai, vector_store_status: :passing }.merge(overrides)))
          get ai_status_admin_system_health_url
          assert_response :success
          assert_select "[data-testid='worker-ai-health-result']" do
            assert_select "[data-testid='worker-process-identity']", text: "worker:1"
            assert_select "p", text: /Geprüft vor/
            assert_select "span", text: status
            assert_select "span", text: configuration
          end
          assert_no_match(/synthetic-token/, response.body)
        end
      end
    end
  end

  test "German family admin cannot queue worker verification" do
    users(:family_admin).update!(locale: "de")
    sign_in users(:family_admin)
    assert_no_enqueued_jobs only: WorkerAiHealthCheckJob do
      post verify_worker_ai_admin_system_health_url
    end
    assert_redirected_to root_path
  end

  test "configuration tab reports missing email and provider configuration without secrets or probes" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    ApplicationMailer.stubs(:perform_deliveries).returns(true)
    ApplicationMailer.stubs(:delivery_method).returns(:smtp)
    ApplicationMailer.stubs(:smtp_settings).returns({ address: nil, port: nil, password: "smtp-secret" })
    ApplicationMailer.stubs(:default).returns({ from: "Sure <sender@sure.local>" })
    ApplicationMailer.stubs(:default_url_options).returns({})
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data", "yahoo_finance" ])
    Setting.stubs(:twelve_data_api_key).returns(nil)
    Setting.stubs(:exchange_rate_provider).returns("twelve_data")
    Provider::TwelveData.any_instance.expects(:usage).never
    Provider::YahooFinance.any_instance.expects(:health_status).never
    AiHealth.expects(:new).never

    ClimateControl.modify("TWELVE_DATA_API_KEY" => nil, "EXCHANGE_RATE_PROVIDER" => nil) do
      get admin_system_health_url(tab: "configuration")
    end

    assert_response :success
    assert_select "button[role='tab'][aria-selected='true']", text: "Configuration"
    assert_select "[data-testid='configuration-smtp']" do
      assert_select "h2", text: "Email (SMTP)"
      assert_select "li", text: "SMTP_ADDRESS"
      assert_match(/SMTP cannot be configured in the admin UI/, response.body)
    end
    assert_select "[data-testid='configuration-securities']" do
      assert_select "span", text: "Incomplete configuration"
      assert_select "dt", text: "Twelve Data"
      assert_select "dd", text: "API key missing"
      assert_select "dt", text: "Yahoo Finance"
    end
    assert_select "[data-testid='configuration-exchange_rates']" do
      assert_select "span", text: "Not configured"
    end
    assert_select "[data-testid='configuration-storage']"
    assert_no_match(/smtp-secret/, response.body)
  end

  test "configuration tab does not expose configured mailer or storage values" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    ApplicationMailer.stubs(:perform_deliveries).returns(true)
    ApplicationMailer.stubs(:delivery_method).returns(:smtp)
    ApplicationMailer.stubs(:smtp_settings).returns({
      address: "smtp.private.test", port: 587, user_name: "private-user", password: "private-password"
    })
    ApplicationMailer.stubs(:default).returns({ from: "Sure <private-sender@private.test>" })
    ApplicationMailer.stubs(:default_url_options).returns({ host: "private-domain.test" })
    Rails.application.config.active_storage.stubs(:service).returns(:generic_s3)
    Rails.application.config.active_storage.stubs(:service_configurations).returns({
      generic_s3: {
        service: "S3", region: "private-region", bucket: "private-bucket", endpoint: "https://private-endpoint.test",
        access_key_id: "private-access-key", secret_access_key: "private-secret"
      }
    })

    get admin_system_health_url(tab: "configuration")

    assert_response :success
    assert_select "[data-testid='configuration-smtp'] span", text: "Configured (not tested)"
    assert_select "[data-testid='configuration-storage'] span", text: "Configured (not tested)"
    assert_no_match(/private-|smtp.private.test/, response.body)
  end

  test "German configuration tab has localized copy without fallback" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    get admin_system_health_url(tab: "configuration", locale: :de)

    assert_response :success
    assert_select "button[role='tab'][aria-selected='true']", text: "Konfiguration"
    assert_select "[data-testid='configuration-smtp'] h2", text: "E-Mail (SMTP)"
    assert_select "[data-testid='configuration-securities'] h2", text: "Marktpreise"
    assert_select "[data-testid='configuration-exchange_rates'] h2", text: "Wechselkurse"
    assert_select "[data-testid='configuration-storage'] h2", text: "Datei-Uploads und Speicher"
    assert_no_match(/translation missing/, response.body)
  end

  test "optional services are at the bottom with neutral absent statuses and collapsed guidance" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    get admin_system_health_url(tab: "configuration")

    assert_response :success
    assert_select "[data-testid='configuration-health'] > :last-child[data-testid='optional-services']" do
      assert_select "h2", text: "Optional services"
      assert_select "details:not([open])", count: 6
      %w[Langfuse Sentry Skylight Stripe PostHog Logtail].each do |name|
        assert_select "summary span", text: name
      end
      assert_select "input, form, button", count: 0
    end
  end

  test "optional service rendering exposes no configured values and creates no clients" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    Langfuse.stubs(:configuration).returns(OpenStruct.new(public_key: "optional-public-secret", secret_key: "optional-langfuse-secret"))
    Sentry.stubs(:configuration).returns(OpenStruct.new(dsn: "optional-sentry-secret", enabled_in_current_env?: true))
    Langfuse.expects(:new).never
    Stripe::StripeClient.expects(:new).never
    PostHog::Client.expects(:new).never
    Sentry.expects(:capture_exception).never
    Logtail::Logger.expects(:create_default_logger).never
    posthog = Rails.configuration.x.posthog.dup
    posthog.api_key = "optional-posthog-secret"
    posthog.host = "https://optional-private-host.test"
    Rails.configuration.x.stubs(:posthog).returns(posthog)

    ClimateControl.modify(
      "LANGFUSE_PUBLIC_KEY" => "optional-public-secret", "LANGFUSE_SECRET_KEY" => "optional-langfuse-secret",
      "SKYLIGHT_AUTHENTICATION" => "optional-skylight-secret", "STRIPE_SECRET_KEY" => "optional-stripe-secret",
      "STRIPE_WEBHOOK_SECRET" => "optional-webhook-secret", "STRIPE_MONTHLY_PRICE_ID" => "optional-monthly-secret",
      "STRIPE_ANNUAL_PRICE_ID" => "optional-annual-secret", "LOGTAIL_API_KEY" => "optional-logtail-secret",
      "LOGTAIL_INGESTING_HOST" => "optional-logtail-host"
    ) do
      get admin_system_health_url(tab: "configuration")
    end

    assert_response :success
    assert_select "[data-testid='optional-services']" do |section|
      assert_no_match(/optional-.*?(secret|host)/, section.first.to_html)
      assert_select "[data-testid='optional-service-langfuse'] summary", text: /Configured \(not tested\)/
      assert_select "[data-testid='optional-service-stripe'] summary", text: /Configured \(not tested\)/
    end
  end

  test "German optional service copy renders with setup guidance" do
    sign_in users(:sure_support_staff)
    stub_healthy_sidekiq
    get admin_system_health_url(tab: "configuration", locale: :de)

    assert_response :success
    assert_select "[data-testid='optional-services'] h2", text: "Optionale Dienste"
    assert_select "[data-testid='optional-service-stripe'] p", text: /STRIPE_WEBHOOK_SECRET/
    assert_no_match(/translation missing/, response.body)
  end

  test "configuration tab preserves super admin authorization" do
    ConfigurationHealth.expects(:new).never
    get admin_system_health_url(tab: "configuration")
    assert_redirected_to new_session_path

    sign_in users(:family_admin)
    get admin_system_health_url(tab: "configuration")
    assert_redirected_to root_path
  end

  private
    # Stubs Rails.cache with an in-process MemoryStore for the duration of
    # the block. Test env normally runs a NullStore (see config/environments/test.rb),
    # under which WorkerAiHealth.record!/.recent (both cache: Rails.cache by
    # default) would silently no-op -- fine for controller tests that don't
    # care about worker results, but these need the round trip to actually work.
    def with_memory_cache
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      yield
    ensure
      Rails.unstub(:cache)
    end

    def worker_snapshot(overrides = {})
      WorkerAiHealth::Snapshot.new(
        **{
          process_identity: "worker:1",
          hostname: "worker",
          pid: 1,
          checked_at: Time.current,
          effective_provider: :openai,
          llm_model: "gpt-4.1",
          llm_endpoint: "https://api.openai.com/v1",
          llm_request_timeout: 60,
          function_calling_status: :supported,
          vector_store_adapter: nil,
          embedding_model: nil,
          embedding_endpoint: nil,
          embedding_dimensions: nil,
          llm_status: :passing,
          vector_store_status: :not_configured,
          failure_codes: []
        }.merge(overrides)
      )
    end

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
