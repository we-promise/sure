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

  # The schema sets only a minimum, and Integer() turns an arbitrarily large
  # cursor into a Bignum that String#[] rejects with RangeError, which failed the
  # whole tool call instead of returning the empty rest of the page.
  test "a cursor past the end of the page returns no text instead of raising" do
    statement = create_statement

    AccountStatement::TextExtractor.any_instance.stubs(:extract).returns(
      AccountStatement::TextExtractor::Result.new(
        pages: [ "page one", "page two" ], page_count: 2, extractable: true, note: nil
      )
    )

    [ 100, 10**30, (10**30).to_s ].each do |from_char|
      result = @fn.call("account_statement_id" => statement.id, "from_page" => 1, "from_char" => from_char)

      assert_equal "", result[:pages].first[:text], "from_char=#{from_char}"
      assert_equal "page two", result[:pages].last[:text]
      assert_equal false, result[:has_more_pages]
    end
  end

  test "a scan too large to send as a PDF is pointed at Images instead" do
    use_ai_routes
    statement = create_statement
    PDF::Reader.stubs(:new).returns(stub(pages: [ stub(text: "") ]))
    Ai::PdfReading.any_instance.stubs(:ways).returns({ pdf: :too_large, text: :no_text_layer, images: nil, ocr: :needs_ocr_route })
    Pdf::PageImages.stubs(:executable).returns("/usr/bin/pdftoppm")

    result = @fn.call("account_statement_id" => statement.id)

    assert_match(/"Read as" set to Images/, result[:note])
  end

  test "without the page renderer, a scan too large for PDF says so instead of suggesting Images" do
    use_ai_routes
    statement = create_statement
    PDF::Reader.stubs(:new).returns(stub(pages: [ stub(text: "") ]))
    Ai::PdfReading.any_instance.stubs(:ways).returns({ pdf: :too_large, text: :no_text_layer, images: nil, ocr: :needs_ocr_route })
    Pdf::PageImages.stubs(:executable).returns(nil)

    result = @fn.call("account_statement_id" => statement.id)

    assert_no_match(/Read as/, result[:note])
    assert_match(/too large/, result[:note])
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
end
