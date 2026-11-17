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

  test "offers only depository accounts the user can write" do
    fn = Assistant::Function::ImportBankStatement.new(users(:family_member))
    pdf_import = PdfImport.create!(family: @user.family, document_type: "bank_statement")

    result = fn.call("pdf_import_id" => pdf_import.id)

    assert_equal "account_required", result[:error]
    offered = result[:available_accounts].map { |account| account[:id] }
    assert_includes offered, accounts(:depository).id
    assert_equal users(:family_member).family.accounts.writable_by(users(:family_member)).visible.depositories.pluck(:id).sort, offered.sort
  end

  test "refuses an account the user cannot write" do
    fn = Assistant::Function::ImportBankStatement.new(users(:family_member))
    pdf_import = PdfImport.create!(family: @user.family, document_type: "bank_statement")
    Ai.expects(:availability).never

    [ accounts(:credit_card), accounts(:investment) ].each do |account|
      result = fn.call("pdf_import_id" => pdf_import.id, "account_id" => account.id)

      assert_equal "account_not_found", result[:error]
      assert_not_includes result[:available_accounts].map { |offered| offered[:id] }, account.id
    end
  end

  test "refuses with the router's reason when no provider can be resolved after the availability check" do
    use_ai_routes
    pdf_import = PdfImport.create!(family: @user.family, document_type: "bank_statement")
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    result = @fn.call("pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id)

    assert_equal "ai_unavailable", result[:error]
    assert_equal "not_configured", result[:reason]
    assert result[:message].present?, "the refusal carries the reason worded for the user"
  end
end
