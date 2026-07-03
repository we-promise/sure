require "test_helper"

class VectorStore::RegistryTest < ActiveSupport::TestCase
  test "adapter_name defaults to openai when access token present" do
    VectorStore::Registry.stubs(:openai_access_token).returns("sk-test")
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_equal :openai, VectorStore::Registry.adapter_name
    end
  end

  test "adapter_name returns nil when no credentials configured" do
    VectorStore::Registry.stubs(:openai_access_token).returns(nil)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_nil VectorStore::Registry.adapter_name
    end
  end

  test "adapter_name respects explicit VECTOR_STORE_PROVIDER" do
    ClimateControl.modify(VECTOR_STORE_PROVIDER: "qdrant") do
      assert_equal :qdrant, VectorStore::Registry.adapter_name
    end
  end

  test "adapter_name falls back to openai for unknown provider" do
    VectorStore::Registry.stubs(:openai_access_token).returns("sk-test")
    ClimateControl.modify(VECTOR_STORE_PROVIDER: "unknown_store") do
      assert_equal :openai, VectorStore::Registry.adapter_name
    end
  end

  test "adapter returns VectorStore::Openai instance when openai configured" do
    VectorStore::Registry.stubs(:openai_access_token).returns("sk-test")
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      adapter = VectorStore::Registry.adapter
      assert_instance_of VectorStore::Openai, adapter
    end
  end

  test "adapter returns nil when nothing configured" do
    VectorStore::Registry.stubs(:openai_access_token).returns(nil)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_nil VectorStore::Registry.adapter
    end
  end

  test "adapter returns VectorStore::Pgvector instance when pgvector configured and available" do
    VectorStore::Pgvector.stubs(:available?).returns(true)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: "pgvector") do
      adapter = VectorStore::Registry.adapter
      assert_instance_of VectorStore::Pgvector, adapter
    end
  end

  test "adapter is nil when pgvector is selected but unavailable" do
    VectorStore::Pgvector.stubs(:available?).returns(false)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: "pgvector") do
      assert_nil VectorStore::Registry.adapter
      assert_not VectorStore.configured?
    end
  end

  test "adapter is nil for the anthropic default when pgvector is unavailable" do
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Pgvector.stubs(:available?).returns(false)
    VectorStore::Registry.stubs(:openai_access_token).returns(nil)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_nil VectorStore::Registry.adapter
    end
  end

  test "adapter builds pgvector for the anthropic default when available" do
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Pgvector.stubs(:available?).returns(true)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_instance_of VectorStore::Pgvector, VectorStore::Registry.adapter
    end
  end

  test "adapter_name defaults to pgvector when LLM_PROVIDER is anthropic" do
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Registry.stubs(:openai_access_token).returns(nil)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_equal :pgvector, VectorStore::Registry.adapter_name
    end
  end

  test "adapter_name routes anthropic installs to pgvector even when OpenAI key is present" do
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Registry.stubs(:openai_access_token).returns("sk-test")
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_equal :pgvector, VectorStore::Registry.adapter_name
    end
  end

  test "explicit VECTOR_STORE_PROVIDER overrides anthropic default" do
    Setting.stubs(:llm_provider).returns("anthropic")
    ClimateControl.modify(VECTOR_STORE_PROVIDER: "qdrant") do
      assert_equal :qdrant, VectorStore::Registry.adapter_name
    end
  end

  test "configured? delegates to adapter presence" do
    VectorStore::Registry.stubs(:adapter).returns(nil)
    assert_not VectorStore.configured?

    VectorStore::Registry.stubs(:adapter).returns(VectorStore::Openai.new(access_token: "sk-test"))
    assert VectorStore.configured?
  end

  test "pgvector_effective? is true when pgvector is explicit" do
    ClimateControl.modify(VECTOR_STORE_PROVIDER: "pgvector") do
      assert VectorStore::Registry.pgvector_effective?
    end
  end

  test "pgvector_effective? is true for the anthropic default (no explicit provider)" do
    Setting.stubs(:llm_provider).returns("anthropic")
    VectorStore::Registry.stubs(:openai_access_token).returns(nil)
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert VectorStore::Registry.pgvector_effective?
    end
  end

  test "pgvector_effective? is false for the openai default" do
    Setting.stubs(:llm_provider).returns("openai")
    VectorStore::Registry.stubs(:openai_access_token).returns("sk-test")
    ClimateControl.modify(VECTOR_STORE_PROVIDER: nil) do
      assert_not VectorStore::Registry.pgvector_effective?
    end
  end
end
