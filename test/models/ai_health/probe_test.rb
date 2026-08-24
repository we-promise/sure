require "test_helper"

class AiHealth::ProbeTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @probe = AiHealth::Probe.new(cache: @cache)
  end

  test "OpenAI LLM probe calls the models endpoint and verifies the configured model" do
    request = stub_request(:get, "http://ollama.example.test:11434/v1/models")
              .with(headers: { "Authorization" => "Bearer local-token" })
              .to_return(
                status: 200,
                headers: { "Content-Type" => "application/json" },
                body: { data: [ { id: "qwen3:8b" } ] }.to_json
              )

    result = @probe.llm(
      provider: :openai,
      endpoint: "http://ollama.example.test:11434/v1",
      access_token: "local-token",
      model: "qwen3:8b"
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
end
