require "test_helper"

# The chat and MCP tool reads a statement through Ai::PdfReading, with an
# optional "Read as".
class Assistant::Function::ImportBankStatementTest < ActiveSupport::TestCase
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

  test "a second extraction for the same statement does not leave another live draft" do
    stub_ai(:extract_pdf, returns: statement)

    first = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)
    assert first[:success], first[:message]
    second = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_not second[:success]
    assert_equal "draft_already_exists", second[:error]
    assert_equal first[:import_id], second[:import_id]
    assert_equal 1, @user.family.imports.where(type: "TransactionImport", source_pdf_import_id: @import.id).count
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

  test "read_as left out is Auto, whatever the import was saved with" do
    @import.update!(read_as: "text")
    reading = Ai::PdfReading.any_instance
    reading.expects(:extract).with { |read_as:, **| read_as == :auto }.raises(Ai::Error::Unavailable, :no_text_layer)

    result = @fn.call("pdf_import_id" => @import.id, "account_id" => @account.id)

    assert_equal "no_text_layer", result[:reason]
    assert_equal "No way to read this PDF is available (no_text_layer).", result[:message], "model-facing, not localized"
  end

  private
    def statement(opening: 44_079.83, closing: 44_079.83 - 24.5 + 2575.0)
      { bank_name: "YourBank", account_holder: nil, account_number: nil, currency: "GBP", opening_balance: opening, closing_balance: closing,
        statement_period: { start_date: "2019-02-01", end_date: "2019-03-01" },
        transactions: [ { date: "2019-02-01", description: "Card payment", amount: -24.5, reference: nil, category: nil },
                        { date: "2019-02-04", description: "Pay", amount: 2575.0, reference: nil, category: nil } ] }
    end
end
