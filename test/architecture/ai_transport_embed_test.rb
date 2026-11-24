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

  test "embeddings follow the returned index and reject a bad permutation" do
    reordered = rows([ 0.1, 0.2, 0.3 ], [ 0.4, 0.5, 0.6 ])
    reordered[:data].reverse!
    stub_embeddings(reordered)

    assert_equal [ [ 0.1, 0.2, 0.3 ], [ 0.4, 0.5, 0.6 ] ], embed(%w[first second]).vectors,
                 "the first text keeps the vector the server indexed 0"

    WebMock.reset!
    invalid = rows([ 0.1, 0.2, 0.3 ], [ 0.4, 0.5, 0.6 ])
    invalid[:data].first[:index] = 2
    stub_embeddings(invalid)

    error = assert_raises(Ai::Error::InvalidOutput) { embed(%w[first second]) }
    assert_match(/Invalid or duplicate embedding record positions/, error.message)
  end

  test "fewer vectors than texts is InvalidOutput, which RubyLLM raises over the 200" do
    stub_embeddings(rows([ 0.1, 0.2, 0.3 ]))

    error = assert_raises(Ai::Error::InvalidOutput) { embed(%w[first second]) }
    assert_match(/Expected 2 embeddings, got 1/, error.message)
  end

  test "a single-text probe with extra vectors is InvalidOutput" do
    # RubyLLM skips its own count check when the input is a string, so this guard is the only
    # thing stopping an extra vector from being treated as the probe's answer.
    stub_embeddings(rows([ 0.1, 0.2, 0.3 ], [ 0.4, 0.5, 0.6 ]))

    endpoint = ai_endpoint(name: "embed", base_url: "http://embed.local:8081/v1", location: :local)
    model = ai_model(name: "nomic-embed-text", endpoint:, capabilities: %i[embedding], embedding_dimensions: 3)

    error = assert_raises(Ai::Error::InvalidOutput) { Ai::Transport.for(endpoint).probe(model, :embedding) }
    assert_match(/expected 1 vectors, got 2/, error.message)
  end

  test "Ai::Embeddings indexes in batches of 50 on the embed route and queries under search_documents" do
    use_ai_routes
    requests = stub_ai

    vectors = Ai::Embeddings.index(Array.new(51) { "chunk #{_1}" }, family: @family)
    query = Ai::Embeddings.query("rent", family: @family, user: users(:family_admin))   # a search is someone's

    assert_equal 51, vectors.size
    assert_equal 768, query.size
    assert_equal [ 50, 1, 1 ], requests.map { _1.texts.size }
    assert_equal %i[embed embed search_documents], requests.map(&:feature)
    assert_equal [ "nomic-embed-text" ], requests.map { _1.model.name }.uniq
  end

  test "an endpoint with static headers is refused before the texts are sent without them" do
    stub = stub_request(:post, URL)
    endpoint = ai_endpoint(name: "embed", base_url: "http://embed.local:8081/v1", location: :local, extra_headers: { "X-Gateway" => "docs" })
    model = ai_model(name: "nomic-embed-text", endpoint:, capabilities: %i[embedding], embedding_dimensions: 3)
    request = Ai::Transport::Base::EmbedRequest.new(feature: :embed, family: @family, model:, texts: %w[secret])

    assert_raises(Ai::Error::Refused) { Ai::Transport.for(endpoint).embed(request) }
    assert_not_requested stub
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
