require "test_helper"

class Assistant::Function::ImportBankStatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::ImportBankStatement.new(@user)
    @openai = Provider::Openai.new("test-key")
  end

  test "model_for falls back to Setting when OPENAI_MODEL env is blank" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "") do
      assert_equal "llama3", @fn.send(:model_for, @openai)
    end
  end

  test "model_for prefers OPENAI_MODEL env when set" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "gpt-4o") do
      assert_equal "gpt-4o", @fn.send(:model_for, @openai)
    end
  end

  test "model_for leaves non-OpenAI providers to their own default" do
    with_env_overrides("OPENAI_MODEL" => "gpt-4o") do
      assert_nil @fn.send(:model_for, Provider::Anthropic.new("test-key"))
    end
  end
end
