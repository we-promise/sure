require "test_helper"

class AiHealth::ProbeTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @probe = AiHealth::Probe.new(cache: @cache)
  end

  test "OpenAI LLM probe calls the models endpoint and verifies the configured model" do
    request = stub_request(:get, "https://api.openai.example.test/v1/models")
              .with(headers: { "Authorization" => "Bearer local-token" })
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { data: [ { id: "gpt-4.1" } ] }.to_json
              )

    result = @probe.llm(
      provider: :openai,
      endpoint: "https://api.openai.example.test/v1",
      access_token: "local-token",
      model: "gpt-4.1"
    )

    assert result.passing?
    assert result.checked_at
    assert_requested request
  end

  test "an unsupported provider is a failing result, not an exception" do
    result = @probe.llm(provider: :mistral, endpoint: "https://api.mistral.example.test/v1", access_token: "token", model: "small")

    assert result.failing?
    assert_equal "unsupported_provider", result.failure_code.to_s
    assert_not_requested :any, /mistral/
  end

  test "timeout honors AI_HEALTH_PROBE_TIMEOUT and falls back for missing or non-positive values" do
    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: "42") do
      assert_equal 42, AiHealth::Probe.timeout
    end

    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: nil) do
      assert_equal AiHealth::Probe::DEFAULT_TIMEOUT, AiHealth::Probe.timeout
    end

    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: "0") do
      assert_equal AiHealth::Probe::DEFAULT_TIMEOUT, AiHealth::Probe.timeout
    end

    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: "-3") do
      assert_equal AiHealth::Probe::DEFAULT_TIMEOUT, AiHealth::Probe.timeout
    end

    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: "not-a-number") do
      assert_equal AiHealth::Probe::DEFAULT_TIMEOUT, AiHealth::Probe.timeout
    end

    assert_equal AiHealth::Probe.timeout, @probe.send(:timeout)
  end

  test "timeout falls back to the self-hosting setting when AI_HEALTH_PROBE_TIMEOUT is unset" do
    Setting.stubs(:ai_health_probe_timeout).returns(30)

    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: nil) do
      assert_equal 30, AiHealth::Probe.timeout
    end

    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: "0") do
      assert_equal 30, AiHealth::Probe.timeout
    end

    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: "42") do
      assert_equal 42, AiHealth::Probe.timeout
    end

    Setting.stubs(:ai_health_probe_timeout).returns(0)
    ClimateControl.modify(AI_HEALTH_PROBE_TIMEOUT: nil) do
      assert_equal AiHealth::Probe::DEFAULT_TIMEOUT, AiHealth::Probe.timeout
    end
  end

  test "OpenAI-compatible LLM probe lists models too, making no chat call" do
    endpoint = "https://api.cloudflare.com/client/v4/accounts/account-id/ai/v1"
    request = stub_request(:get, "#{endpoint}/models")
              .with(headers: { "Authorization" => "Bearer cf-token" })
              .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                         body: { data: [ { id: "@cf/zai-org/glm-5.2" } ] }.to_json)
    chat = stub_request(:post, "#{endpoint}/chat/completions")

    result = @probe.llm(
      provider: :openai,
      endpoint: endpoint,
      access_token: "cf-token",
      model: "@cf/zai-org/glm-5.2"
    )

    assert result.passing?
    assert_requested request
    assert_not_requested chat
  end

  test "LLM probe sends OPENAI_EXTRA_HEADERS, as production calls do" do
    request = stub_request(:get, "https://llm.example.test/v1/models")
              .with(headers: { "X-Team" => "home" })
              .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { data: [ { id: "qwen3" } ] }.to_json)

    ClimateControl.modify(OPENAI_EXTRA_HEADERS: { "X-Team" => "home" }.to_json) do
      assert @probe.llm(provider: :openai, endpoint: "https://llm.example.test/v1", access_token: "t", model: "qwen3").passing?
    end
    assert_requested request
  end

  test "LLM probe reports a spent balance and a wrong key by name" do
    stub_request(:get, "https://llm.example.test/v1/models").to_return(
      { status: 429, headers: { "Content-Type" => "application/json" }, body: { error: { message: "no credits", code: "insufficient_quota" } }.to_json },
      { status: 401, headers: { "Content-Type" => "application/json" }, body: { error: { message: "Invalid API key" } }.to_json }
    )
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    spent = AiHealth::Probe.new(cache: @cache, force: true).llm(provider: :openai, endpoint: "https://llm.example.test/v1", access_token: "t", model: "m")
    wrong = AiHealth::Probe.new(cache: @cache, force: true).llm(provider: :openai, endpoint: "https://llm.example.test/v1", access_token: "t", model: "m")

    assert_equal [ :no_credit, 429 ], [ spent.failure_code, spent.http_status ]
    assert_equal [ :unauthorized, 401 ], [ wrong.failure_code, wrong.http_status ]
  end

  test "Anthropic LLM probe calls the models endpoint and verifies the configured model" do
    request = stub_request(:get, "https://api.anthropic.com/v1/models/claude-sonnet-4-6")
              .with(headers: { "X-Api-Key" => "anthropic-token" })
              .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                         body: { id: "claude-sonnet-4-6", type: "model", display_name: "Claude Sonnet 4.6", created_at: "2026-01-01T00:00:00Z" }.to_json)

    result = @probe.llm(
      provider: :anthropic,
      endpoint: "https://api.anthropic.com",
      access_token: "anthropic-token",
      model: "claude-sonnet-4-6"
    )

    assert result.passing?
    assert_requested request
  end

  test "the Anthropic models probe takes its proxy from Sure's resolver, as the calls it checks do" do
    url = "https://api.anthropic.com/v1/models/claude-sonnet-4-6"
    Ai::Transport::Http.stubs(:proxy_for).returns(nil)
    Ai::Transport::Http.expects(:proxy_for).with(url).returns("http://proxy.example.test:3128").at_least_once
    stub_request(:get, url).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { id: "claude-sonnet-4-6" }.to_json)

    result = @probe.llm(provider: :anthropic, endpoint: "https://api.anthropic.com", access_token: "anthropic-token", model: "claude-sonnet-4-6")

    assert result.passing?
  end

  test "an Anthropic lookup answered for another model fails; a dated snapshot of an alias passes" do
    url = "https://api.anthropic.com/v1/models/claude-sonnet-4-6"
    transport = Ai::Transport.for(Ai::Config::Endpoint.new(name: "anthropic", protocol: :anthropic, api_key: "anthropic-token"))
    model = Ai::Config::Model.new(endpoint: transport.endpoint, name: "claude-sonnet-4-6")

    stub_request(:get, url).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { id: "claude-haiku-4-5" }.to_json)
    assert_raises(Ai::Error::ModelMissing) { transport.probe(model, :models) }

    stub_request(:get, url).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { id: "claude-sonnet-4-6-20260101" }.to_json)
    assert_equal "claude-sonnet-4-6-20260101", transport.probe(model, :models)
  end

  test "an Anthropic model the API doesn't have fails the models probe" do
    stub_request(:get, "https://api.anthropic.com/v1/models/claude-nope")
      .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                 body: { type: "error", error: { type: "not_found_error", message: "model: claude-nope" } }.to_json)
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.llm(provider: :anthropic, endpoint: "https://api.anthropic.com", access_token: "anthropic-token", model: "claude-nope")

    assert_not result.passing?
    assert_equal 404, result.http_status
    assert_equal "model_not_available", result.failure_code.to_s
  end

  test "an Anthropic lookup maps by status whatever the body, and a garbled 200 is invalid output" do
    url = "https://api.anthropic.com/v1/models/claude-sonnet-4-6"
    transport = Ai::Transport.for(Ai::Config::Endpoint.new(name: "anthropic", protocol: :anthropic, api_key: "anthropic-token"))
    model = Ai::Config::Model.new(endpoint: transport.endpoint, name: "claude-sonnet-4-6")
    {
      { status: 503, body: { error: "busy" }.to_json } => Ai::Error::Upstream,
      { status: 404, body: "<html>not here</html>" } => Ai::Error::Refused,
      { status: 200, body: "<html>sign in</html>" } => Ai::Error::InvalidOutput
    }.each do |response, error|
      stub_request(:get, url).to_return(**response, headers: { "Content-Type" => "application/json" })

      assert_raises(error, response.inspect) { transport.probe(model, :models) }
    end
  end

  test "PDF text-extraction probe exercises only the OpenAI text processor and validates its result" do
    response = {
      "choices" => [
        {
          "message" => {
            "content" => {
              document_type: "bank_statement",
              summary: "A synthetic bank statement containing no customer data.",
              extracted_data: {
                institution_name: AiHealth::Probe::SyntheticPdf::INSTITUTION
              }
            }.to_json
          }
        }
      ]
    }
    client = mock("openai_client")
    captured = nil
    client.expects(:chat).with do |params|
      captured = params
      true
    end.returns(response)
    Ai::Transport::Http.stubs(:openai_client).returns(client)
    Provider::Openai::PdfProcessor.any_instance.expects(:convert_pdf_to_images).never

    result = @probe.pdf_text_extraction(
      provider: :openai,
      endpoint: "https://api.cloudflare.example.test/v1",
      access_token: "token",
      model: "text-model",
      openai_compatible: true
    )

    assert result.passing?
    instructions = captured.dig(:parameters, :messages, 0, :content)
    document_text = captured.dig(:parameters, :messages, 1, :content)
    assert_not_includes instructions, AiHealth::Probe::SyntheticPdf::INSTITUTION
    assert_includes document_text, AiHealth::Probe::SyntheticPdf::INSTITUTION
  end

  test "PDF vision probe exercises only the OpenAI vision processor and validates its result" do
    response = {
      "choices" => [
        {
          "message" => {
            "content" => {
              document_type: "bank_statement",
              summary: "A synthetic bank statement containing no customer data.",
              extracted_data: {
                institution_name: AiHealth::Probe::SyntheticPdf::INSTITUTION
              }
            }.to_json
          }
        }
      ]
    }
    client = mock("openai_client")
    captured = nil
    client.expects(:chat).with do |params|
      captured = params
      true
    end.returns(response)
    Ai::Transport::Http.stubs(:openai_client).returns(client)
    Provider::Openai::PdfProcessor.any_instance.expects(:convert_pdf_to_images).once.returns([ "encoded-page" ])

    result = @probe.pdf_vision_processing(
      provider: :openai,
      endpoint: "https://api.cloudflare.example.test/v1",
      access_token: "token",
      model: "vision-model",
      openai_compatible: true
    )

    assert result.passing?
    instructions = captured.dig(:parameters, :messages, 0, :content)
    assert_not_includes instructions, AiHealth::Probe::SyntheticPdf::INSTITUTION
  end

  test "PDF processing probes require the expected institution in the standard result fields" do
    response = {
      "choices" => [
        {
          "message" => {
            "content" => {
              document_type: "bank_statement",
              summary: "A different bank statement.",
              extracted_data: { institution_name: "Another Bank" }
            }.to_json
          }
        }
      ]
    }
    client = stub(chat: response)
    Ai::Transport::Http.stubs(:openai_client).returns(client)
    Provider::Openai::PdfProcessor.any_instance.stubs(:convert_pdf_to_images).returns([ "encoded-page" ])
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.pdf_vision_processing(
      provider: :openai,
      endpoint: "https://api.cloudflare.example.test/v1",
      access_token: "token",
      model: "vision-model",
      openai_compatible: true
    )

    assert result.failing?
    assert_equal :invalid_response, result.failure_code
  end

  test "PDF vision probe sends the synthetic PDF as an Anthropic document block" do
    tool_use = Struct.new(:type, :input).new(
      :tool_use,
      {
        "document_type" => "bank_statement",
        "summary" => "A synthetic bank statement containing no customer data.",
        "extracted_data" => {
          "institution_name" => AiHealth::Probe::SyntheticPdf::INSTITUTION
        }
      }
    )
    response = Struct.new(:content, :usage).new([ tool_use ], nil)
    messages = mock("anthropic_messages")
    messages.expects(:create).with do |params|
      source = params.dig(:messages, 0, :content, 0, :source)
      extracted_data_schema = params.dig(:tools, 0, :input_schema, :properties, :extracted_data)
      source[:media_type] == "application/pdf" &&
        Base64.strict_decode64(source[:data]) == AiHealth::Probe::SyntheticPdf.bytes &&
        extracted_data_schema[:properties].key?(:institution_name) &&
        extracted_data_schema[:required].empty? &&
        !params[:system_].include?(AiHealth::Probe::SyntheticPdf::INSTITUTION)
    end.returns(response)
    Ai::Transport::Http.stubs(:anthropic_client).returns(stub(messages: messages))

    result = @probe.pdf_vision_processing(
      provider: :anthropic,
      endpoint: "https://api.anthropic.com",
      access_token: "token",
      model: "claude-sonnet-4-6"
    )

    assert result.passing?
  end

  test "failed LLM probe writes a system-wide debug entry and Rails log without secrets" do
    models = stub(list: { "data" => [ { "id" => "another-model" } ] })
    Ai::Transport::Http.stubs(:openai_client).returns(stub(models: models))
    endpoint = URI::HTTP.build(
      userinfo: "operator:uri-secret",
      host: "ollama",
      port: 11_434,
      path: "/v1",
      query: "api_key=query-secret"
    ).to_s
    Rails.logger.expects(:error).with do |message|
      message.include?("AI health llm liveness probe failed") &&
        !message.include?("secret-token") &&
        !message.include?("uri-secret") &&
        !message.include?("query-secret")
    end

    assert_difference -> { DebugLogEntry.where(category: "ai_health").count }, 1 do
      @result = @probe.llm(
        provider: :openai,
        endpoint: endpoint,
        access_token: "secret-token",
        model: "missing-model"
      )
    end

    assert @result.failing?
    assert_equal :model_not_available, @result.failure_code

    entry = DebugLogEntry.where(category: "ai_health")
                         .where("metadata ->> 'model' = ?", "missing-model")
                         .order(:id)
                         .last
    assert_equal "error", entry.level
    assert_equal "AiHealth::Probe", entry.source
    assert_equal "openai", entry.provider_key
    assert_nil entry.family
    assert_nil entry.account
    assert_equal "http://ollama:11434/v1", entry.metadata.fetch("endpoint")
    assert_equal "model_not_available", entry.metadata.fetch("failure_code")
    assert_no_match(/secret-token|uri-secret|query-secret/, entry.metadata.to_json)
  end

  test "probe results are cached to avoid repeated requests and failure logs" do
    models = mock("models")
    models.expects(:list).once.returns({ "data" => [ { "id" => "gpt-4.1" } ] })
    client = stub(models: models)
    Ai::Transport::Http.stubs(:openai_client).returns(client)

    2.times do
      result = @probe.llm(
        provider: :openai,
        endpoint: "https://api.openai.com/v1",
        access_token: "token",
        model: "gpt-4.1"
      )
      assert result.passing?
    end
  end

  test "forced probe bypasses the cached result" do
    models = mock("models")
    models.expects(:list).twice.returns({ "data" => [ { "id" => "gpt-4.1" } ] })
    client = stub(models: models)
    Ai::Transport::Http.stubs(:openai_client).returns(client)

    arguments = {
      provider: :openai,
      endpoint: "https://api.openai.com/v1",
      access_token: "token",
      model: "gpt-4.1"
    }
    @probe.llm(**arguments)

    forced_probe = AiHealth::Probe.new(cache: @cache, force: true)
    assert forced_probe.llm(**arguments).passing?
  end

  test "hosted vector-store probe calls the non-destructive list endpoint" do
    request = stub_request(:get, "https://api.openai.example.test/v1/vector_stores")
              .with(query: { limit: 1 }, headers: { "Authorization" => "Bearer token" })
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { data: [] }.to_json
              )

    result = @probe.openai_vector_store(
      endpoint: "https://api.openai.example.test/v1",
      access_token: "token"
    )

    assert result.passing?
    assert_requested request
  end

  test "pgvector probe verifies the extension, table, and a real query" do
    connection = mock("connection")
    connection.expects(:extension_enabled?).with("vector").returns(true)
    connection.expects(:table_exists?).with("vector_store_chunks").returns(true)
    connection.expects(:quote_table_name).with("vector_store_chunks").returns(%("vector_store_chunks"))
    connection.expects(:select_value).with('SELECT 1 FROM "vector_store_chunks" LIMIT 1').returns(nil)

    assert @probe.pgvector(connection: connection).passing?
  end

  test "embedding probe sends a small request and verifies dimensions" do
    request = stub_request(:post, "http://ollama.example.test:11434/v1/embeddings")
              .with(
                body: hash_including(model: "nomic-embed-text", input: Ai::Transport::Base::PROBE_EMBEDDING_INPUT)
              )
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { data: [ { embedding: [ 0.1, 0.2, 0.3 ] } ], model: "nomic-embed-text", usage: { prompt_tokens: 4, total_tokens: 4 } }.to_json
              )

    result = @probe.embedding(
      endpoint: "http://ollama.example.test:11434/v1",
      access_token: nil,
      model: "nomic-embed-text",
      dimensions: 3
    )

    assert result.passing?
    assert_requested request
  end

  test "embedding probe fails on a vector with a component that isn't a finite number" do
    stub_request(:post, "http://ollama:11434/v1/embeddings").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { data: [ { embedding: [ 0.1, nil, 0.3 ] } ], model: "nomic-embed-text", usage: { prompt_tokens: 4, total_tokens: 4 } }.to_json
    )
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.embedding(endpoint: "http://ollama:11434/v1", access_token: nil, model: "nomic-embed-text", dimensions: 3)

    assert result.failing?
    assert_equal :invalid_response, result.failure_code
  end

  test "embedding probe fails when returned dimensions do not match configuration" do
    stub_request(:post, "http://ollama:11434/v1/embeddings").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { data: [ { embedding: [ 0.1, 0.2 ] } ], model: "nomic-embed-text", usage: { prompt_tokens: 4, total_tokens: 4 } }.to_json
    )
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.embedding(
      endpoint: "http://ollama:11434/v1",
      access_token: nil,
      model: "nomic-embed-text",
      dimensions: 3
    )

    assert result.failing?
    assert_equal :dimensions_mismatch, result.failure_code
  end

  test "function-calling probe sends the assistant's tools payload and passes when the model calls one" do
    endpoint = "https://openrouter.example.test/api/v1"
    request = stub_request(:post, "#{endpoint}/chat/completions")
              .with { |req|
                body = JSON.parse(req.body)
                tool = body.dig("tools", 0, "function")

                body["model"] == "tools-model" &&
                  body.dig("messages", 0, "content") == Ai::Transport::Base::PROBE_TOOL_PROMPT &&
                  tool["name"] == Ai::Transport::Base::PROBE_TOOL_NAME &&
                  tool["parameters"] == Ai::Transport::Base::PROBE_TOOL_SCHEMA.deep_stringify_keys
              }
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: {
                  id: "chatcmpl-1",
                  model: "tools-model",
                  choices: [
                    {
                      index: 0,
                      finish_reason: "tool_calls",
                      message: {
                        role: "assistant",
                        tool_calls: [
                          { id: "call_1", type: "function", function: { name: "sure_health_check", arguments: "{}" } }
                        ]
                      }
                    }
                  ]
                }.to_json
              )

    result = @probe.function_calling(
      provider: :openai,
      endpoint: endpoint,
      access_token: "token",
      model: "tools-model"
    )

    assert result.passing?
    assert_requested request
  end

  test "function-calling probe fails when the model answers without calling the tool" do
    endpoint = "https://openrouter.example.test/api/v1"
    stub_request(:post, "#{endpoint}/chat/completions").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { choices: [ { message: { content: "ok" } } ] }.to_json
    )
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.function_calling(
      provider: :openai,
      endpoint: endpoint,
      access_token: "token",
      model: "chat-only-model"
    )

    assert result.failing?
    assert_equal :no_tool_call, result.failure_code
  end

  test "function-calling probe confirms a refusal by re-asking without the tools" do
    endpoint = "https://openrouter.example.test/api/v1"
    stub_tools_request(endpoint).to_return(
      status: 404,
      headers: { "Content-Type" => "application/json" },
      body: { error: { message: "No endpoints found that support tool use." } }.to_json
    )
    control = stub_control_request(endpoint).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { choices: [ { message: { content: "ok" } } ] }.to_json
    )
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.function_calling(
      provider: :openai,
      endpoint: endpoint,
      access_token: "token",
      model: "tngtech/deepseek-r1t2-chimera:free"
    )

    assert result.failing?
    assert_equal :tools_refused, result.failure_code
    assert_requested control
  end

  test "function-calling probe does not blame the tools for a client error the request gets either way" do
    endpoint = "https://models.example.test/v1"
    stub_tools_request(endpoint).to_return(status: 422, body: "{}", headers: { "Content-Type" => "application/json" })
    control = stub_control_request(endpoint).to_return(
      status: 422,
      body: "{}",
      headers: { "Content-Type" => "application/json" }
    )
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.function_calling(
      provider: :openai,
      endpoint: endpoint,
      access_token: "token",
      model: "picky-model"
    )

    assert result.failing?
    assert_equal :request_failed, result.failure_code
    assert_equal 422, result.http_status
    assert_requested control
  end

  test "function-calling probe does not re-ask when the service said not now" do
    endpoint = "https://models.example.test/v1"
    stub_tools_request(endpoint).to_return(status: 429, body: "{}", headers: { "Content-Type" => "application/json" })
    control = stub_control_request(endpoint)
    Rails.logger.stubs(:error)
    DebugLogEntry.stubs(:capture)

    result = @probe.function_calling(
      provider: :openai,
      endpoint: endpoint,
      access_token: "token",
      model: "busy-model"
    )

    assert result.failing?
    assert_equal :request_failed, result.failure_code
    assert_equal 429, result.http_status
    assert_not_requested control
  end

  test "function-calling probe uses the responses endpoint when the assistant would" do
    request = stub_request(:post, "https://api.openai.example.test/v1/responses")
              .with { |req|
                tool = JSON.parse(req.body).dig("tools", 0)

                tool["type"] == "function" && tool["name"] == Ai::Transport::Base::PROBE_TOOL_NAME
              }
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { id: "resp_1", model: "gpt-4.1", status: "completed",
                        output: [ { type: "function_call", id: "fc_1", call_id: "call_1", name: "sure_health_check", arguments: "{}" } ] }.to_json
              )

    result = @probe.function_calling(
      provider: :openai,
      endpoint: "https://api.openai.example.test/v1",
      access_token: "token",
      model: "gpt-4.1",
      use_responses_endpoint: true
    )

    assert result.passing?
    assert_requested request
  end

  test "function-calling probe reads an Anthropic tool_use block" do
    request = stub_request(:post, "https://api.anthropic.com/v1/messages")
              .with { |req| JSON.parse(req.body).dig("tools", 0, "input_schema") == Ai::Transport::Base::PROBE_TOOL_SCHEMA.deep_stringify_keys }
              .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
                id: "msg_1", type: "message", role: "assistant", model: "claude-sonnet-4-6", stop_reason: "tool_use",
                content: [ { type: "tool_use", id: "toolu_1", name: "sure_health_check", input: { status: "ok" } } ],
                usage: { input_tokens: 20, output_tokens: 10 }
              }.to_json)

    result = @probe.function_calling(
      provider: :anthropic,
      endpoint: "https://api.anthropic.com",
      access_token: "token",
      model: "claude-sonnet-4-6"
    )

    assert result.passing?
    assert_requested request
  end

  test "probes build no clients of their own" do
    source = Rails.root.join("app/models/ai_health/probe.rb").read

    assert_no_match(/(OpenAI::Client|Anthropic::Client|Faraday)\.new\b/, source)
  end

  private
    def stub_tools_request(endpoint)
      stub_request(:post, "#{endpoint}/chat/completions").with { |request| JSON.parse(request.body).key?("tools") }
    end

    def stub_control_request(endpoint)
      stub_request(:post, "#{endpoint}/chat/completions").with { |request| !JSON.parse(request.body).key?("tools") }
    end
end
