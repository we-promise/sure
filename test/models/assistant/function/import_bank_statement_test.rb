require "test_helper"

class Assistant::Function::ImportBankStatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::ImportBankStatement.new(@user)
  end

  test "model_for falls back to Setting when OPENAI_MODEL env is blank" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "") do
      assert_equal "llama3", @fn.send(:model_for, Provider::Openai.new("test-key"))
    end
  end

  test "model_for prefers OPENAI_MODEL env when set" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "gpt-4o") do
      assert_equal "gpt-4o", @fn.send(:model_for, Provider::Openai.new("test-key"))
    end
  end

  test "model_for leaves non-OpenAI providers to their own default" do
    with_env_overrides("OPENAI_MODEL" => "gpt-4o") do
      assert_nil @fn.send(:model_for, Provider::Anthropic.new("test-key"))
    end
  end

  test "model_for uses the family's provider model instead of installation settings" do
    with_env_overrides("OPENAI_MODEL" => "installation-model") do
      provider = Provider::Openai.new("test-family-key", model: Provider::Openai::DEFAULT_MODEL, use_global_settings: false)
      assert_equal Provider::Openai::DEFAULT_MODEL, @fn.send(:model_for, provider)
    end
  end
end
