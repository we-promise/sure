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

  test "OpenAI-compatible LLM probe calls chat completions instead of the models endpoint" do
    endpoint = "https://api.cloudflare.com/client/v4/accounts/account-id/ai/v1"
    request = stub_request(:post, "#{endpoint}/chat/completions")
              .with(
                headers: { "Authorization" => "Bearer cf-token" },
                body: {
                  model: "@cf/zai-org/glm-5.2",
                  messages: [ { role: "user", content: AiHealth::Probe::CHAT_TEST_INPUT } ]
                }
              )
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { choices: [ { message: { content: "OK" } } ] }.to_json
              )

    result = @probe.llm(
      provider: :openai,
      endpoint: endpoint,
      access_token: "cf-token",
      model: "@cf/zai-org/glm-5.2",
      openai_compatible: true
    )

    assert result.passing?
    assert result.checked_at
    assert_requested request
  end

  test "Anthropic LLM probe calls the models endpoint and verifies the configured model" do
    model_info = Struct.new(:id).new("claude-sonnet-4-6")
    models = mock("models")
    models.expects(:retrieve).with("claude-sonnet-4-6").returns(model_info)
    client = mock("anthropic_client")
    client.expects(:models).returns(models)
    @probe.stubs(:anthropic_client).returns(client)

    result = @probe.llm(
      provider: :anthropic,
      endpoint: "https://api.anthropic.com",
      access_token: "anthropic-token",
      model: "claude-sonnet-4-6"
    )

    assert result.passing?
  end

  test "synthetic PDF is valid and contains no customer data" do
    pdf = @probe.send(:synthetic_pdf)
    reader = PDF::Reader.new(StringIO.new(pdf))

    assert_equal 1, reader.page_count
    AiHealth::Probe::PDF_TEST_LINES.each do |line|
      assert_includes reader.pages.first.text, line
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
                institution_name: AiHealth::Probe::PDF_TEST_INSTITUTION
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
    @probe.stubs(:openai_client).returns(client)
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
    assert_not_includes instructions, AiHealth::Probe::PDF_TEST_INSTITUTION
    assert_includes document_text, AiHealth::Probe::PDF_TEST_INSTITUTION
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
                institution_name: AiHealth::Probe::PDF_TEST_INSTITUTION
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
    @probe.stubs(:openai_client).returns(client)
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
    assert_not_includes instructions, AiHealth::Probe::PDF_TEST_INSTITUTION
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
    @probe.stubs(:openai_client).returns(client)
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
          "institution_name" => AiHealth::Probe::PDF_TEST_INSTITUTION
        }
      }
    )
    response = Struct.new(:content, :usage).new([ tool_use ], nil)
    messages = mock("anthropic_messages")
    messages.expects(:create).with do |params|
      source = params.dig(:messages, 0, :content, 0, :source)
      extracted_data_schema = params.dig(:tools, 0, :input_schema, :properties, :extracted_data)
      source[:media_type] == "application/pdf" &&
        Base64.strict_decode64(source[:data]) == @probe.send(:synthetic_pdf) &&
        extracted_data_schema[:properties].key?(:institution_name) &&
        extracted_data_schema[:required].empty? &&
        !params[:system_].include?(AiHealth::Probe::PDF_TEST_INSTITUTION)
    end.returns(response)
    @probe.stubs(:anthropic_client).returns(stub(messages: messages))

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
    @probe.stubs(:openai_client).returns(stub(models: models))
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
    @probe.stubs(:openai_client).returns(client)

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
    @probe.stubs(:openai_client).returns(client)

    arguments = {
      provider: :openai,
      endpoint: "https://api.openai.com/v1",
      access_token: "token",
      model: "gpt-4.1"
    }
    @probe.llm(**arguments)

    forced_probe = AiHealth::Probe.new(cache: @cache, force: true)
    forced_probe.stubs(:openai_client).returns(client)
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
                body: {
                  model: "nomic-embed-text",
                  input: AiHealth::Probe::EMBEDDING_TEST_INPUT
                }
              )
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { data: [ { embedding: [ 0.1, 0.2, 0.3 ] } ] }.to_json
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

  test "embedding probe fails when returned dimensions do not match configuration" do
    response = Struct.new(:body).new({ "data" => [ { "embedding" => [ 0.1, 0.2 ] } ] })
    client = stub
    client.stubs(:post).yields(Struct.new(:body).new).returns(response)
    @probe.stubs(:embedding_client).returns(client)
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
                  body.dig("messages", 0, "content") == AiHealth::Probe::FUNCTION_CALL_TEST_INPUT &&
                  tool["name"] == AiHealth::Probe::FUNCTION_CALL_TEST_TOOL[:name] &&
                  tool["strict"] == true
              }
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: {
                  choices: [
                    {
                      message: {
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

                tool["type"] == "function" && tool["name"] == AiHealth::Probe::FUNCTION_CALL_TEST_TOOL[:name]
              }
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { output: [ { type: "function_call", name: "sure_health_check", arguments: "{}" } ] }.to_json
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
    response = Struct.new(:content).new([ Struct.new(:type, :name).new(:tool_use, "sure_health_check") ])
    messages = mock("anthropic_messages")
    messages.expects(:create).with do |params|
      params[:tools].first[:input_schema] == AiHealth::Probe::FUNCTION_CALL_TEST_TOOL[:schema] &&
        !params[:tools].first.key?(:strict)
    end.returns(response)
    @probe.stubs(:anthropic_client).returns(stub(messages: messages))

    result = @probe.function_calling(
      provider: :anthropic,
      endpoint: "https://api.anthropic.com",
      access_token: "token",
      model: "claude-sonnet-4-6"
    )

    assert result.passing?
  end

  private
    def stub_tools_request(endpoint)
      stub_request(:post, "#{endpoint}/chat/completions").with { |request| JSON.parse(request.body).key?("tools") }
    end

    def stub_control_request(endpoint)
      stub_request(:post, "#{endpoint}/chat/completions").with { |request| !JSON.parse(request.body).key?("tools") }
    end
end
