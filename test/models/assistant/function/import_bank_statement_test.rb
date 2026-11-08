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
    assert_equal "TransactionImport", @user.family.imports.find(result[:import_id]).type
    assert_equal [ "application/pdf" ], requests.sole.attachments.map(&:content_type)
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

  private
    def statement(closing: 44_079.83 - 24.5 + 2575.0)
      { bank_name: "YourBank", account_holder: nil, account_number: nil, currency: "GBP", opening_balance: 44_079.83, closing_balance: closing,
        statement_period: { start_date: "2019-02-01", end_date: "2019-03-01" },
        transactions: [ { date: "2019-02-01", description: "Card payment", amount: -24.5, reference: nil, category: nil },
                        { date: "2019-02-04", description: "Pay", amount: 2575.0, reference: nil, category: nil } ] }
    end
end
