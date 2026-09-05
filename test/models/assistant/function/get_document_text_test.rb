require "test_helper"

class Assistant::Function::GetDocumentTextTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @fn = Assistant::Function::GetDocumentText.new(@user)
  end

  # A one-page PDF with a real text layer, built inline so the test does not
  # depend on a binary fixture.
  def pdf_bytes(text)
    <<~PDF
      %PDF-1.4
      1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
      2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
      3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
      4 0 obj<</Length #{text.length + 44}>>stream
      BT /F1 12 Tf 72 720 Td (#{text}) Tj ET
      endstream
      endobj
      5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
      trailer<</Root 1 0 R>>
    PDF
  end

  def create_statement(filename: "releve.pdf", content: nil, content_type: "application/pdf", account: nil)
    statement = @family.account_statements.build(
      account: account,
      filename: filename,
      content_type: content_type,
      byte_size: 100,
      checksum: SecureRandom.hex(16),
      content_sha256: SecureRandom.hex(32),
      source: :manual_upload,
      upload_status: :stored,
      review_status: account ? :linked : :unmatched,
      currency: "USD"
    )
    statement.original_file.attach(
      io: StringIO.new(content || pdf_bytes("Echeance 275,00 EUR")),
      filename: filename,
      content_type: content_type
    )
    statement.save!
    statement
  end

  test "has correct name and requires a statement id" do
    assert_equal "get_document_text", @fn.name
    assert_includes @fn.params_schema[:required], "account_statement_id"
  end

  test "is only offered to preview users" do
    plain = users(:family_member)
    plain.update!(preferences: (plain.preferences || {}).merge("preview_features_enabled" => false))

    names = Assistant.function_classes(plain).map(&:name)

    assert_not_includes names, "get_document_text"
    assert_includes Assistant.function_classes(@user).map(&:name), "get_document_text"
  end

  test "returns the text of a plain text document" do
    statement = create_statement(filename: "notes.csv", content: "date,amount\n2026-01-01,275.00",
                                 content_type: "text/csv")

    result = @fn.call("account_statement_id" => statement.id)

    assert_equal true, result[:extractable]
    assert_equal 1, result[:page_count]
    assert_match(/275.00/, result[:pages].first[:text])
    assert_equal false, result[:has_more_pages]
  end

  # The window's size guard only fires once a page has already been selected, so
  # a text file returned as one giant page went out whole and blew the per-call
  # budget the tool documents.
  test "a large text file is paged instead of returned whole" do
    rows = (1..2_000).map { |i| "2026-01-01,#{i},LIBELLE #{i}" }.join("\n")
    statement = create_statement(filename: "big.csv", content: rows, content_type: "text/csv")

    result = @fn.call("account_statement_id" => statement.id)
    returned = result[:pages].sum { |page| page[:text].length }

    assert_operator result[:page_count], :>, 1
    assert_operator returned, :<=, Assistant::Function::GetDocumentText::MAX_CHARS
    assert_equal true, result[:has_more_pages]
    assert_equal result[:to_page] + 1, result[:next_page]
  end

  # The tail of an oversized page used to be unreachable: it was cut and the
  # note said so, and no combination of from_page could get at the rest.
  test "a single page longer than the budget is served in chunks with a cursor" do
    max = Assistant::Function::GetDocumentText::MAX_CHARS
    oversized = ("A" * max) + ("B" * 5_000)
    statement = create_statement

    AccountStatement::TextExtractor.any_instance.stubs(:extract).returns(
      AccountStatement::TextExtractor::Result.new(
        pages: [ oversized ], page_count: 1, extractable: true, note: nil
      )
    )

    first = @fn.call("account_statement_id" => statement.id)
    page = first[:pages].first

    assert_equal max, page[:text].length
    assert_equal true, page[:continued]
    assert_equal true, first[:has_more_pages]
    assert_equal 1, first[:next_page], "the cursor stays on the page until its text runs out"
    assert_equal max, first[:next_from_char]

    second = @fn.call("account_statement_id" => statement.id,
                      "from_page" => first[:next_page], "from_char" => first[:next_from_char])
    tail = second[:pages].first

    assert_equal "B" * 5_000, tail[:text], "the rest of the page is reachable"
    assert_equal max, tail[:from_char]
    assert_equal false, second[:has_more_pages]
    assert_nil second[:next_from_char]
  end

  test "an oversized page hands the following pages back once it is exhausted" do
    max = Assistant::Function::GetDocumentText::MAX_CHARS
    statement = create_statement

    AccountStatement::TextExtractor.any_instance.stubs(:extract).returns(
      AccountStatement::TextExtractor::Result.new(
        pages: [ "A" * (max + 100), "page two" ], page_count: 2, extractable: true, note: nil
      )
    )

    first = @fn.call("account_statement_id" => statement.id)

    assert_equal 1, first[:next_page]
    assert_equal max, first[:next_from_char]

    second = @fn.call("account_statement_id" => statement.id, "from_page" => 1, "from_char" => max)

    assert_equal [ 1, 2 ], second[:pages].map { |p| p[:page] }
    assert_equal "page two", second[:pages].last[:text]
    assert_equal false, second[:has_more_pages]
  end

  test "reports a scan with no text layer as unreadable and names the reason" do
    statement = create_statement

    blank_pages = [ stub(text: "  "), stub(text: "") ]
    PDF::Reader.stubs(:new).returns(stub(pages: blank_pages))

    result = @fn.call("account_statement_id" => statement.id)

    assert_equal false, result[:extractable]
    assert_equal 2, result[:page_count]
    assert_match(/no OCR/i, result[:note])
    assert_not result.key?(:pages), "an empty pages array would read as a document that says nothing"
  end

  test "reports an unparseable PDF distinctly from a scan" do
    statement = create_statement(content: "%PDF-1.4 truncated garbage")

    result = @fn.call("account_statement_id" => statement.id)

    assert_equal false, result[:extractable]
    assert_match(/could not be parsed/, result[:note])
  end

  test "pages a long document and says where to continue" do
    statement = create_statement

    long_page = "x" * 7_000
    PDF::Reader.stubs(:new).returns(stub(pages: [ stub(text: long_page), stub(text: long_page), stub(text: long_page) ]))

    first = @fn.call("account_statement_id" => statement.id)

    assert_equal 1, first[:from_page]
    assert_equal 1, first[:to_page], "a second 7k page would exceed the window, so only whole page 1 is returned"
    assert_equal true, first[:has_more_pages]
    assert_equal 2, first[:next_page]

    second = @fn.call("account_statement_id" => statement.id, "from_page" => 3)

    assert_equal 3, second[:from_page]
    assert_equal false, second[:has_more_pages]
  end

  test "refuses an unknown id" do
    result = @fn.call("account_statement_id" => SecureRandom.uuid)

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "refuses a malformed id without raising" do
    result = @fn.call("account_statement_id" => "not-a-uuid")

    assert_equal "not_found", result[:error]
  end

  test "does not return the text of a statement on an inaccessible account" do
    statement = create_statement(account: accounts(:investment))

    member = Assistant::Function::GetDocumentText.new(users(:family_member))
    member.instance_variable_get(:@user).update!(
      preferences: { "preview_features_enabled" => true }
    )

    result = member.call("account_statement_id" => statement.id)

    assert_equal "not_found", result[:error],
                 "full document text is a bigger disclosure than metadata and must follow account access"
  end

  test "rejects an unsupported binary type with a reason" do
    statement = create_statement(filename: "sheet.xlsx", content: "PK\x03\x04binary",
                                 content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

    result = @fn.call("account_statement_id" => statement.id)

    assert_equal false, result[:extractable]
    assert_match(/PDF and plain-text/, result[:note])
  end
end
