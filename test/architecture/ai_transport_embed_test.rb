require "test_helper"

# The `embed` half of the transport contract: what the compatible transport
# sends, the vector checks on top of RubyLLM's own, error mapping, the `embed.ai` event and
# usage rows; and Ai::Embeddings on the `embed` route. Stubbed through WebMock.
class AiTransportEmbedTest < ActiveSupport::TestCase
  URL = "http://embed.local:8081/v1/embeddings".freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  setup do
    @family = families(:dylan_family)
    Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
  end

  test "sends today's request, the model and the texts, and returns a vector per text" do
    bodies = stub_embeddings(rows([ 0.1, 0.2, 0.3 ], [ 0.4, 0.5, 0.6 ]))

    response = embed(%w[first second])

    assert_equal({ "model" => "nomic-embed-text", "input" => %w[first second] }, bodies.first)
    assert_equal [ [ 0.1, 0.2, 0.3 ], [ 0.4, 0.5, 0.6 ] ], response.vectors
    assert_equal 7, response.usage.input_tokens
  end

  test "a single text still comes back as a list of one vector" do
    stub_embeddings(rows([ 0.1, 0.2, 0.3 ]))

    assert_equal [ [ 0.1, 0.2, 0.3 ] ], embed([ "only" ]).vectors
  end

  test "fewer vectors than texts is InvalidOutput, which RubyLLM raises over the 200" do
    stub_embeddings(rows([ 0.1, 0.2, 0.3 ]))

    error = assert_raises(Ai::Error::InvalidOutput) { embed(%w[first second]) }
    assert_match(/Expected 2 embeddings, got 1/, error.message)
  end

  test "a vector of the wrong size is InvalidOutput" do
    stub_embeddings(rows([ 0.1, 0.2 ]))

    assert_raises(Ai::Error::InvalidOutput) { embed([ "only" ]) }
  end

  test "maps a 401 and retries a 503" do
    stub_request(:post, URL).to_return(status: 401, headers: JSON_HEADERS, body: { error: { message: "bad key" } }.to_json)
    assert_raises(Ai::Error::Unauthorized) { embed([ "x" ]) }

    WebMock.reset!
    stub_request(:post, URL)
      .to_return({ status: 503, headers: JSON_HEADERS, body: { error: { message: "busy" } }.to_json },
                 { status: 200, headers: JSON_HEADERS, body: rows([ 0.1, 0.2, 0.3 ]).to_json })
    assert_equal 1, embed([ "x" ], max_retries: 1).vectors.size
  end

  test "one embed.ai event per call, without the texts, and a usage row under the feature" do
    stub_embeddings(rows([ 0.1, 0.2, 0.3 ], [ 0.4, 0.5, 0.6 ]))

    events = capture_ai_events { embed([ "ACME PAYROLL", "RENT" ], family: @family) }

    event = events.sole
    assert_equal "embed.ai", event.name
    assert_equal({ items: 2 }, event.payload[:request])
    assert_equal({ vectors: 2, dimensions: 3 }, event.payload[:output])
    assert_not_includes event.payload.to_s, "ACME"
    assert_equal [ "embed" ], @family.llm_usages.where(operation: "embed").pluck(:operation)
  end

  test "Anthropic doesn't embed" do
    endpoint = ai_endpoint(name: "anthropic", protocol: :anthropic, base_url: "https://anthropic.example.test")
    request = Ai::Transport::Base::EmbedRequest.new(feature: :embed, model: ai_model(endpoint:), texts: [ "x" ])

    assert_raises(NotImplementedError) { Ai::Transport.for(endpoint).embed(request) }
  end

  test "Ai::Embeddings indexes in batches of 50 on the embed route and queries under search_documents" do
    use_ai_routes
    requests = stub_ai

    vectors = Ai::Embeddings.index(Array.new(51) { "chunk #{_1}" }, family: @family)
    query = Ai::Embeddings.query("rent", family: @family)

    assert_equal 51, vectors.size
    assert_equal 768, query.size
    assert_equal [ 50, 1, 1 ], requests.map { _1.texts.size }
    assert_equal %i[embed embed search_documents], requests.map(&:feature)
    assert_equal [ "nomic-embed-text" ], requests.map { _1.model.name }.uniq
  end

  test "Ai::Embeddings raises Unavailable with the router's reason" do
    use_no_ai

    error = assert_raises(Ai::Error::Unavailable) { Ai::Embeddings.query("rent", family: @family) }
    assert_equal :not_configured, error.reason
  end

  test "Ai::Embeddings has no model to call when the embed route is an OpenAI vector store" do
    store = ai_endpoint(name: "openai", vector_store: true)
    config = AiTestHelper.build_ai_config([ ai_model(endpoint: store, name: "vector_store", capabilities: %i[embedding]) ],
                                          { embed: %w[openai/vector_store] }, vector_store_backend: :openai)

    Ai::Config.with(config) do
      assert_equal :capability_missing, assert_raises(Ai::Error::Unavailable) { Ai::Embeddings.index([ "x" ], family: @family) }.reason
    end
  end

  private
    def embed(texts, family: nil, max_retries: 0)
      endpoint = ai_endpoint(name: "embed", base_url: "http://embed.local:8081/v1", location: :local, max_retries:)
      model = ai_model(name: "nomic-embed-text", endpoint:, capabilities: %i[embedding], embedding_dimensions: 3)
      request = Ai::Transport::Base::EmbedRequest.new(feature: :embed, family:, model:, texts:)
      Ai::Transport.for(endpoint).embed(request)
    end

    def rows(*vectors)
      { object: "list", model: "nomic-embed-text", data: vectors.each_with_index.map { |embedding, index| { object: "embedding", index:, embedding: } },
        usage: { prompt_tokens: 7, total_tokens: 7 } }
    end

    def stub_embeddings(body)
      bodies = []
      stub_request(:post, URL).to_return(lambda do |request|
        bodies << JSON.parse(request.body)
        { status: 200, headers: JSON_HEADERS, body: body.to_json }
      end)
      bodies
    end
end
