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

  test "configured? delegates to adapter presence" do
    VectorStore::Registry.stubs(:adapter).returns(nil)
    assert_not VectorStore.configured?

    VectorStore::Registry.stubs(:adapter).returns(VectorStore::Openai.new(access_token: "sk-test"))
    assert VectorStore.configured?
  end
end
