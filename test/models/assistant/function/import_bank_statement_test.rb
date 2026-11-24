require "test_helper"

# The chat and MCP tool reads a statement through Ai::PdfReading, with an
# optional "Read as".
class Assistant::Function::ImportBankStatementTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    use_ai_routes
    @user = users(:family_admin)
    @fn = Assistant::Function::ImportBankStatement.new(@user)
    @import = imports(:pdf_processed)
    @import.pdf_file.attach(io: StringIO.new(file_fixture("statements/bac_ocr.pdf").binread), filename: "bac.pdf", content_type: "application/pdf")
    @account = accounts(:depository)
  end

  test "extracts through the plumbing and creates a transaction import" do
    requests = stub_ai(:extract_pdf, returns: statement)

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert result[:success], result[:message]
    assert_equal 2, result[:transaction_count]
    assert_equal "pdf", result[:read_as]
    assert result[:checks_passed]
    draft = @user.family.imports.find(result[:import_id])
    assert_equal "TransactionImport", draft.type
    assert_equal @import.id, draft.source_pdf_import_id
    assert_equal [ "application/pdf" ], requests.sole.attachments.map(&:content_type)
  end

  test "a statement on an account the user can't see is not found, and its PDF isn't read" do
    statement = AccountStatement.new(family: @user.family, account: @account)
    statement.stubs(:viewable_by?).with(@user).returns(false)
    PdfImport.any_instance.stubs(:account_statement).returns(statement)
    stub_ai(:extract_pdf) { flunk "the PDF must not be read" }

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_not result[:success]
    assert_equal "PDF import not found", result[:error]
  end

  test "a second extraction for the same statement does not leave another live draft" do
    stub_ai(:extract_pdf, returns: statement)

    first = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)
    assert first[:success], first[:message]
    second = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_not second[:success]
    assert_equal "draft_already_exists", second[:error]
    assert_equal first[:import_id], second[:import_id]
    assert_match(/delete draft import/i, second[:message])
    assert_match(/write access/i, second[:message])
    assert_match(/delete draft import/i, second[:available_actions].sole)
    assert_match(/draft_already_exists/, Assistant::Function::ImportBankStatement.description)
    assert_equal 1, @user.family.imports.where(type: "TransactionImport", source_pdf_import_id: @import.id).count
  end

  test "a failed revert that restored entries still blocks another draft" do
    stub_ai(:extract_pdf, returns: statement)
    first = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)
    draft = @user.family.imports.find(first[:import_id])
    create_transaction(account: @account, import: draft, name: "Restored entry", amount: 10)
    draft.update!(status: :revert_failed)

    second = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_not second[:success]
    assert_equal "draft_already_exists", second[:error]
    assert_equal draft.id, second[:import_id]
    assert_match(/revert import .* removes the transactions it published, then delete it/, second[:message])
  end

  test "a failed import that still owns committed entries blocks another draft" do
    stub_ai(:extract_pdf, returns: statement)
    first = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)
    draft = @user.family.imports.find(first[:import_id])
    create_transaction(account: @account, import: draft, name: "Committed entry", amount: 10)
    draft.update!(status: :failed)

    second = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_not second[:success]
    assert_equal "draft_already_exists", second[:error]
  end

  test "a row-generation failure rolls the draft back so a retry can recreate it" do
    stub_ai(:extract_pdf, returns: statement)
    TransactionImport.any_instance.stubs(:generate_rows_from_csv).raises(StandardError, "bad row")

    assert_raises(StandardError) { @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id) }
    assert_equal 0, @user.family.imports.where(type: "TransactionImport", source_pdf_import_id: @import.id).count,
                 "no empty draft is left to block the retry"

    TransactionImport.any_instance.unstub(:generate_rows_from_csv)
    retry_result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)
    assert retry_result[:success], retry_result[:message]
  end

  test "read_as reads it the way asked, and says when the extraction failed its checks" do
    requests = stub_ai(:extract_pdf, returns: statement(closing: 1.0))

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id, "read_as" => "text")

    assert result[:success]
    assert_equal "text", result[:read_as]
    assert_not result[:checks_passed]
    assert_match "failed its checks", result[:message]
    assert_empty requests.sole.attachments
  end

  test "a statement without balances is reported as unchecked, not as failed" do
    stub_ai(:extract_pdf, returns: statement(opening: nil, closing: nil))

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert result[:success]
    assert_not result[:checks_passed]
    assert_match "balances weren't found", result[:message]
    assert_no_match "failed its checks", result[:message]
  end

  test "a way the route can't do answers with the reason" do
    use_ai_routes(extract_pdf: %w[gpu/qwen3-8b])
    stub_ai(:extract_pdf, returns: statement)

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id, "read_as" => "images")

    assert_not result[:success]
    assert_equal "needs_vision", result[:reason]
  end

  test "read_as is offered as an enum" do
    assert_equal PdfImport::READ_AS, @fn.params_schema.dig(:properties, :read_as, :enum)
  end

  test "a route gone after the availability check is the same refusal, not a crash" do
    use_no_ai
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_equal "unavailable", result[:error]
    assert_equal "not_configured", result[:reason]
    assert result[:message].present?, "the refusal carries the reason worded for the user"
  end

  test "a provider error never puts its message in the log or the model's answer" do
    Ai::PdfReading.any_instance.stubs(:extract)
                  .raises(Ai::Error::Upstream, "503: account 12345678 could not be read")
    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_equal "extraction_failed", result[:error]
    assert_not_includes result[:message], "12345678"
    assert_not_includes result[:message], "could not be read"
  end

  test "read_as left out is Auto, whatever the import was saved with" do
    @import.update!(read_as: "text")
    reading = Ai::PdfReading.any_instance
    reading.expects(:extract).with { |read_as:, **| read_as == :auto }.raises(Ai::Error::Unavailable, :no_text_layer)

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_equal "no_text_layer", result[:reason]
    assert_equal "No way to read this PDF is available (no_text_layer).", result[:message], "model-facing, not localized"
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
    Ai::PdfReading.any_instance.expects(:extract).never

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
    Ai::PdfReading.any_instance.expects(:extract).never

    result = Assistant::Function::ImportBankStatement.new(member).call(
      "pdf_import_id" => pdf_import.id, "account_id" => read_only.id
    )

    assert_equal "account_not_found", result[:error]
  end

  test "an account shared with full control goes on to extraction" do
    use_ai_routes
    member = users(:family_member)
    pdf_import = PdfImport.create!(family: member.family, document_type: "bank_statement")
    Ai::PdfReading.any_instance.expects(:extract).once.raises(Ai::Error::Unavailable, :no_text_layer)

    result = Assistant::Function::ImportBankStatement.new(member).call(
      "pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id
    )

    assert_equal "no_text_layer", result[:reason]
  end

  # The web answers 404 for a statement-backed import the user cannot view, so
  # the statement is neither sent to the model nor summarised back.
  test "an import of a statement the user cannot view is not found" do
    member = users(:family_member)
    statement = AccountStatement.create_from_upload!(
      family: member.family,
      account: accounts(:investment),
      file: uploaded_file(
        filename: "statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    pdf_import = PdfImport.create_from_statement!(statement: statement)
    pdf_import.update!(document_type: "bank_statement")
    assert_not statement.viewable_by?(member)
    use_ai_routes
    Ai::PdfReading.any_instance.expects(:extract).never

    result = Assistant::Function::ImportBankStatement.new(member).call(
      "pdf_import_id" => pdf_import.id, "account_id" => accounts(:depository).id
    )

    assert_equal "PDF import not found", result[:error]
  end

  private
    def statement(opening: 44_079.83, closing: 44_079.83 - 24.5 + 2575.0)
      { bank_name: "YourBank", account_holder: nil, account_number: nil, currency: "GBP", opening_balance: opening, closing_balance: closing,
        statement_period: { start_date: "2019-02-01", end_date: "2019-03-01" },
        transactions: [ { date: "2019-02-01", description: "Card payment", amount: -24.5, reference: nil, category: nil },
                        { date: "2019-02-04", description: "Pay", amount: 2575.0, reference: nil, category: nil } ] }
    end
end
