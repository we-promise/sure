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

  test "refuses with the router's reason when no provider can be resolved after the availability check" do
    use_ai_routes
    pdf_import = PdfImport.create!(family: @user.family, document_type: "bank_statement")
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    result = @fn.call("pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id)

    assert_equal "ai_unavailable", result[:error]
    assert_equal "not_configured", result[:reason]
    assert result[:message].present?, "the refusal carries the reason worded for the user"
  end

  # --- Accounts: the ones the user can write to, as on the web and the API ---

  test "without an account it lists the depository accounts the user can write to" do
    member = users(:family_member)
    pdf_import = PdfImport.create!(family: member.family, document_type: "bank_statement")

    result = Assistant::Function::ImportBankStatement.new(member).call("pdf_import_id" => pdf_import.id)

    assert_equal "account_required", result[:error]
    ids = result[:available_accounts].map { |a| a[:id] }
    assert_includes ids, accounts(:depository).id
    assert_not_includes ids, accounts(:connected).id, "listed another member's private account"
  end

  test "an unknown account id is refused with the same list" do
    member = users(:family_member)
    pdf_import = PdfImport.create!(family: member.family, document_type: "bank_statement")

    result = Assistant::Function::ImportBankStatement.new(member).call(
      "pdf_import_id" => pdf_import.id, "account_id" => SecureRandom.uuid
    )

    assert_equal "account_not_found", result[:error]
    ids = result[:available_accounts].map { |a| a[:id] }
    assert_includes ids, accounts(:depository).id
    assert_not_includes ids, accounts(:connected).id
  end

  test "another member's private account is refused before any extraction" do
    member = users(:family_member)
    pdf_import = PdfImport.create!(family: member.family, document_type: "bank_statement")
    use_ai_routes
    Provider::Registry.expects(:preferred_llm_provider).never

    assert_no_difference -> { Import.count } do
      result = Assistant::Function::ImportBankStatement.new(member).call(
        "pdf_import_id" => pdf_import.id, "account_id" => accounts(:connected).id
      )

      assert_equal "account_not_found", result[:error]
    end
  end

  test "an account shared read-only is refused" do
    member = users(:family_member)
    read_only = accounts(:credit_card)
    assert_equal :read_only, read_only.permission_for(member)
    pdf_import = PdfImport.create!(family: member.family, document_type: "bank_statement")
    use_ai_routes
    Provider::Registry.expects(:preferred_llm_provider).never

    result = Assistant::Function::ImportBankStatement.new(member).call(
      "pdf_import_id" => pdf_import.id, "account_id" => read_only.id
    )

    assert_equal "account_not_found", result[:error]
  end

  test "an account shared with full control goes on to extraction" do
    use_ai_routes
    member = users(:family_member)
    pdf_import = PdfImport.create!(family: member.family, document_type: "bank_statement")
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    result = Assistant::Function::ImportBankStatement.new(member).call(
      "pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id
    )

    assert_equal "ai_unavailable", result[:error]
  end

  # The web answers 404 for a statement-backed import the user cannot view, so
  # the statement is neither sent to the model nor summarised back.
  test "an import of a statement the user cannot view is not found" do
    member = users(:family_member)
    pdf_import = statement_import_on(accounts(:investment))
    assert_not pdf_import.account_statement.viewable_by?(member)
    use_ai_routes
    Provider::Registry.expects(:preferred_llm_provider).never

    result = Assistant::Function::ImportBankStatement.new(member).call(
      "pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id
    )

    assert_equal "PDF import not found", result[:error]
  end

  # The web lets only those who can manage a statement act on its import, so
  # the tool does not turn a statement someone can only read into an import.
  test "an import of a statement the user can only read is refused before any extraction" do
    member = users(:family_member)
    pdf_import = statement_import_on(accounts(:credit_card))
    assert pdf_import.account_statement.viewable_by?(member)
    assert_not pdf_import.account_statement.manageable_by?(member)
    use_ai_routes
    Provider::Registry.expects(:preferred_llm_provider).never

    assert_no_difference -> { Import.count } do
      result = Assistant::Function::ImportBankStatement.new(member).call(
        "pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id
      )

      assert_equal "statement_not_manageable", result[:error]
    end
  end

  # The transactions come from the statement, so the import made from them is
  # as private as the statement.
  test "the import made from a statement keeps that statement's privacy" do
    pdf_import = statement_import_on(accounts(:investment))
    use_ai_routes
    provider = mock("llm_provider")
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.stubs(:extract_bank_statement).returns(
      OpenStruct.new(success?: true, data: { transactions: [ { date: "2026-10-01", amount: "-5.0", name: "Coffee" } ] })
    )

    result = @fn.call("pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id)

    assert result[:success], result.inspect
    import = Import.find(result[:import_id])
    assert_equal pdf_import.account_statement, import.account_statement
    assert import.viewable_by?(@user)
    assert_not import.viewable_by?(users(:family_member)), "another member can read a private statement's transactions"
  end

  private
    def statement_import_on(account)
      statement = AccountStatement.create_from_upload!(
        family: account.family,
        account: account,
        file: uploaded_file(
          filename: "statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
      PdfImport.create_from_statement!(statement: statement).tap { |import| import.update!(document_type: "bank_statement") }
    end
end
