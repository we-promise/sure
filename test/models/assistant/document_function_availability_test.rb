require "test_helper"

class Assistant::DocumentFunctionAvailabilityTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "document search is absent without a family context" do
    assert_not_includes Assistant.function_classes, Assistant::Function::SearchFamilyFiles
  end

  %w[anthropic openrouter].each do |provider|
    test "explicit family #{provider} disables search without disabling statement extraction" do
      @family.create_ai_configuration!(provider: provider, api_key: "synthetic-family-key", model: provider == "openrouter" ? "openai/gpt-4.1-mini" : Provider::Anthropic::DEFAULT_MODEL)

      with_env_overrides("VECTOR_STORE_PROVIDER" => "qdrant") do
        functions = Assistant.function_classes(@user)

        assert_not_includes functions, Assistant::Function::SearchFamilyFiles
        assert_includes functions, Assistant::Function::ImportBankStatement
      end
    end
  end

  test "explicit family OpenAI includes document search before the first upload" do
    @family.create_ai_configuration!(provider: "openai", api_key: "synthetic-family-key")

    assert_includes Assistant.function_classes(@user), Assistant::Function::SearchFamilyFiles
  end

  test "legacy configured adapters retain document search without a family override" do
    VectorStore::Pgvector.stubs(:available?).returns(true)

    %w[openai pgvector qdrant].each do |adapter|
      with_env_overrides("VECTOR_STORE_PROVIDER" => adapter, "OPENAI_ACCESS_TOKEN" => "synthetic-installation-key") do
        assert_includes Assistant.function_classes(@user), Assistant::Function::SearchFamilyFiles
      end
    end
  end

  test "document search is absent when the legacy adapter is unavailable" do
    VectorStore::Pgvector.stubs(:available?).returns(false)

    with_env_overrides("VECTOR_STORE_PROVIDER" => "pgvector") do
      assert_not_includes Assistant.function_classes(@user), Assistant::Function::SearchFamilyFiles
    end
  end
end
