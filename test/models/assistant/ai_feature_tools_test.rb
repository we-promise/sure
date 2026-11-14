require "test_helper"

# An AI-dependent tool is listed only while its feature is available, for chat and MCP alike,
# since both list Assistant.function_classes.
class Assistant::AiFeatureToolsTest < ActiveSupport::TestCase
  setup { @user = users(:family_admin) }

  test "import_bank_statement is listed only when extract_pdf is available" do
    use_ai_routes
    assert_includes Assistant.function_classes(@user), Assistant::Function::ImportBankStatement

    use_ai_routes(extract_pdf: [])
    assert_not_includes Assistant.function_classes(@user), Assistant::Function::ImportBankStatement
  end

  test "search_family_files stays listed without AI, as today" do
    use_no_ai

    assert_includes Assistant.function_classes(@user), Assistant::Function::SearchFamilyFiles
    assert_includes Assistant.function_classes(@user), Assistant::Function::GetTransactions
  end

  test "the tool returns the router's reason when called anyway" do
    use_no_ai
    Assistant.expects(:builtin_provider).never

    result = Assistant::Function::ImportBankStatement.new(@user)
                                                     .call("pdf_import_id" => imports(:pdf_with_rows).id, "account_id" => accounts(:depository).id)

    assert_equal "ai_unavailable", result[:error]
    assert_equal "not_configured", result[:reason]
  end
end
