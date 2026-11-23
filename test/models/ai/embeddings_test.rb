require "test_helper"

class Ai::EmbeddingsTest < ActiveSupport::TestCase
  # The request actually sent, as #5659 checked on main: the key saved in Settings reaches OpenAI's
  # own URL and never a separate embedding server, which gets its own token or no Authorization
  # header at all.
  test "the OpenAI key saved in Settings goes to OpenAI only, and a separate server gets its own token" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    Setting.openai_access_token = "sk-saved"
    family = families(:dylan_family)
    body = { data: [ { embedding: [ 0.1 ], index: 0 } ], model: "nomic-embed-text", usage: { prompt_tokens: 1, total_tokens: 1 } }.to_json
    json = { "Content-Type" => "application/json" }
    separate = stub_request(:post, "http://embeddings.example.test:11434/v1/embeddings")
      .with { |request| request.headers["Authorization"].nil? }
      .to_return(body:, headers: json)
    separate_with_token = stub_request(:post, "http://embeddings.example.test:11434/v1/embeddings")
      .with(headers: { "Authorization" => "Bearer emb-token" }).to_return(body:, headers: json)
    openai = stub_request(:post, "https://api.openai.com/v1/embeddings")
      .with(headers: { "Authorization" => "Bearer sk-saved" }).to_return(body:, headers: json)

    embed_with = ->(env) do
      ai_env = %w[OPENAI_ACCESS_TOKEN OPENAI_URI_BASE EMBEDDING_ACCESS_TOKEN EMBEDDING_URI_BASE EMBEDDING_DIMENSIONS].index_with { nil }
      with_env_overrides(ai_env.merge("VECTOR_STORE_PROVIDER" => "pgvector", "EMBEDDING_DIMENSIONS" => "1").merge(env)) do
        Ai::Embeddings.index([ "text" ], family:)
      end
    end
    embed_with.call("EMBEDDING_URI_BASE" => "http://embeddings.example.test:11434/v1")
    embed_with.call("EMBEDDING_URI_BASE" => "http://embeddings.example.test:11434/v1", "EMBEDDING_ACCESS_TOKEN" => "emb-token")
    embed_with.call({})

    assert_requested separate, times: 1
    assert_requested separate_with_token, times: 1
    assert_requested openai, times: 1
  end
end
