require "test_helper"

class VectorStoreTest < ActiveSupport::TestCase
  # The embedding settings apply to pgvector and Qdrant, which embed through an embedding server.
  EMBEDDING_ENVIRONMENT = %w[
    EMBEDDING_MODEL EMBEDDING_DIMENSIONS EMBEDDING_URI_BASE
    EMBEDDING_ACCESS_TOKEN OPENAI_URI_BASE OPENAI_ACCESS_TOKEN
  ].index_with(nil).merge("VECTOR_STORE_PROVIDER" => "pgvector").freeze

  test "embedding defaults use a matching model and vector width" do
    ClimateControl.modify(EMBEDDING_ENVIRONMENT) do
      assert_equal "mxbai-embed-large", VectorStore.embedding_model
      assert_equal 1024, VectorStore.embedding_dimensions
    end
  end

  test "embedding credentials match runtime environment precedence" do
    ClimateControl.modify(EMBEDDING_ENVIRONMENT.merge(
      "EMBEDDING_ACCESS_TOKEN" => "embedding-token",
      "OPENAI_ACCESS_TOKEN" => "openai-token"
    )) do
      assert_equal "embedding-token", VectorStore.embedding_access_token
    end

    ClimateControl.modify(EMBEDDING_ENVIRONMENT.merge(
      "OPENAI_ACCESS_TOKEN" => "openai-token"
    )) do
      assert_equal "openai-token", VectorStore.embedding_access_token
    end

    ClimateControl.modify(EMBEDDING_ENVIRONMENT) do
      assert_nil VectorStore.embedding_access_token
    end
  end

  # The fallbacks include the OpenAI values saved in Settings.
  test "embedding credentials fall back to the OpenAI settings" do
    Setting.openai_access_token = "setting-token"
    Setting.openai_uri_base = "http://llama.local:8080/v1"

    ClimateControl.modify(EMBEDDING_ENVIRONMENT) do
      assert_equal "setting-token", VectorStore.embedding_access_token
      assert_equal "http://llama.local:8080/v1", VectorStore.embedding_uri_base
    end
  end
end
