require "test_helper"

# PDF reading, the input step before extract_pdf's generations: Auto's order,
# its tuning, the ways a route can't use, falling back on failed checks, flagging the best when
# nothing passes, batches with no page limit, and OCR's two steps. Model calls through stub_ai.
class Ai::PdfReadingTest < ActiveSupport::TestCase
  BAC_ROWS = [
    [ "2019-02-01", -24.5 ], [ "2019-02-01", -20.0 ], [ "2019-02-03", -30.0 ], [ "2019-02-04", 2575.0 ], [ "2019-02-11", 300.0 ],
    [ "2019-02-16", -50.0 ], [ "2019-02-17", -40.0 ], [ "2019-02-17", -78.34 ], [ "2019-02-18", 2575.0 ], [ "2019-02-18", -15.0 ],
    [ "2019-02-24", -150.0 ], [ "2019-02-24", 25.0 ], [ "2019-02-28", -987.33 ]
  ].freeze

  setup do
    use_ai_routes
    @family = families(:dylan_family)
    @bac = file_fixture("statements/bac_ocr.pdf").binread
    @scan = file_fixture("statements/impact_scanned.pdf").binread
  end

  test "Auto sends the PDF itself to a model with documents, within the preset's limits" do
    requests = stub_ai(:extract_pdf, returns: statement(BAC_ROWS))

    outcome = reading(@bac).extract

    assert_equal :pdf, outcome.way
    assert outcome.passed?
    assert_equal [ "application/pdf" ], requests.sole.attachments.map(&:content_type)
    assert_equal 13, outcome.value[:transactions].size
    assert_equal "gpt-4.1-mini", outcome.model
  end

  test "each document route takes the PDF only within its own limits" do
    skip_without_pdftoppm
    limited = Ai::Config::Model.new(endpoint: Ai::Config::Endpoint.new(name: :limited, protocol: :compatible, preset: :openai,
                                                                        base_url: "https://api.openai.com/v1"),
                                    name: "gpt-4.1-mini", capabilities: %i[structured_output documents])
    unlimited = Ai::Config::Model.new(endpoint: Ai::Config::Endpoint.new(name: :unlimited, protocol: :compatible,
                                                                          base_url: "http://docs.local:8080/v1", location: :local),
                                      name: "doc-reader", capabilities: %i[structured_output documents])

    with_reading_routes(limited, unlimited) do
      reader = reading(blank_pdf(pages: 101))   # over the OpenAI preset's 100 pages

      assert_nil reader.ways[:pdf], "the second route can take it"
      assert_equal [ unlimited ], reader.send(:plan_for, :pdf).routes.map(&:model)
    end
  end

  test "a scan too large for the PDF limits, read as PDF, says it's too large" do
    skip_without_pdftoppm
    limited = Ai::Config::Model.new(endpoint: Ai::Config::Endpoint.new(name: :limited, protocol: :compatible, preset: :openai,
                                                                        base_url: "https://api.openai.com/v1"),
                                    name: "gpt-4.1-mini", capabilities: %i[structured_output documents])

    with_reading_routes(limited) do
      error = assert_raises(Ai::Error::Unavailable) { reading(blank_pdf(pages: 101)).extract(read_as: :pdf) }

      assert_equal :too_large, error.reason
    end
  end

  test "a text model reads the text layer, page by page, and every check runs on it" do
    requests = stub_ai(:extract_pdf, returns: statement(BAC_ROWS))

    with_reading_routes(text_model) do
      reader = reading(@bac)
      assert_equal({ pdf: :needs_documents, text: nil, images: :needs_vision, ocr: :needs_ocr_route }, reader.ways)

      outcome = reader.extract

      assert_equal :text, outcome.way
      assert outcome.checks.amounts_in_source
      assert_operator outcome.checks.dates_anchored, :>=, 0.5
    end
    assert_empty requests.sole.attachments
    assert_match "--- Page 1 ---", requests.sole.input
    assert_match "Cardpayment-HighStPetrolStation", requests.sole.input
  end

  test "a model with a large context window reads the text layer in one chunk a page" do
    requests = stub_ai(:extract_pdf, returns: statement(BAC_ROWS))

    with_reading_routes(text_model.with(context_window: 1_000_000)) do
      assert_equal :text, reading(@bac).extract(read_as: :text).way
    end
    assert_match "Cardpayment-HighStPetrolStation", requests.sole.input
  end

  test "long text pages are chunked at line boundaries unless a line itself is too long" do
    reader = reading("page one")
    reader.stubs(:chunk_chars).returns(12)
    text = "one two\nthree four\n#{"x" * 20}\nlast line"

    units, = reader.send(:text_units, [ text ])

    assert_equal [ "one two\n", "three four\n", "x" * 12, "x" * 8 + "\n", "last line" ], units.map(&:text)
    assert_equal [ 1, 1, 1, 1, 1 ], units.map(&:first_page)
  end

  test "a scan with no vision model and no OCR is unavailable: an empty text layer is never sent" do
    requests = stub_ai(:extract_pdf, returns: statement([]))

    with_reading_routes(text_model) do
      error = assert_raises(Ai::Error::Unavailable) { reading(@scan).extract }
      assert_equal :no_text_layer, error.reason
    end
    assert_empty requests
  end

  test "a scan goes to a vision model as page images, rendered for the batch" do
    skip_without_pdftoppm
    requests = stub_ai(:extract_pdf, returns: statement([ [ "2019-10-02", -4.23 ] ], opening: 10.0, closing: 5.77))

    with_reading_routes(vision_model) do
      outcome = reading(@scan).extract

      assert_equal :images, outcome.way
      assert outcome.passed?
    end
    assert_equal [ "page-1.png", "page-2.png" ], requests.sole.attachments.map(&:filename)
  end

  test "when the text layer's extraction fails its checks, Auto reads the pages as images" do
    skip_without_pdftoppm
    wrong = BAC_ROWS.map { |date, amount| [ date, -amount ] }
    requests = stub_ai(:extract_pdf) { |request| request.attachments.any? ? statement(BAC_ROWS) : statement(wrong) }

    with_reading_routes(vision_model) do
      outcome = reading(@bac).extract

      assert_equal :images, outcome.way
      assert outcome.passed?
      assert_equal [ :text, :images ], outcome.attempts.map { _1[:way] }
      assert_equal false, outcome.attempts.first.dig(:checks, :passed)
    end
    assert_equal 2, requests.size
  end

  test "Auto starts from the way that last passed for this account and model" do
    skip_without_pdftoppm
    requests = stub_ai(:extract_pdf, returns: statement(BAC_ROWS))

    with_reading_routes(vision_model) do
      assert_equal :images, reading(@bac).extract(start: :images).way
      assert_equal %i[images text], reading(@bac).order(:auto, start: :images)
      assert_equal %i[text images], reading(@bac).order(:auto, start: :pdf), "a way the route can't use isn't a start"
    end
    assert requests.sole.attachments.any?
  end

  test "Read as runs that way only, and a way the route can't do says why" do
    stub_ai(:extract_pdf, returns: statement(BAC_ROWS))

    with_reading_routes(text_model) do
      assert_equal :text, reading(@bac).extract(read_as: :text).way
      error = assert_raises(Ai::Error::Unavailable) { reading(@bac).extract(read_as: :images) }
      assert_equal :needs_vision, error.reason
    end
  end

  test "a text layer that omits a scanned page keeps the extraction incomplete" do
    stub_ai(:extract_pdf, returns: statement(BAC_ROWS))
    Pdf::TextExtractor.stubs(:pages).returns([ "Cardpayment-HighStPetrolStation", "" ])
    Pdf::PageImages.stubs(:page_count).returns(2)

    with_reading_routes(text_model) do
      outcome = reading(@bac).extract(read_as: :text)

      assert_equal :text, outcome.way
      assert_equal false, outcome.checks.complete, "the blank second page may hold transactions"
      assert outcome.flagged?
    end
  end

  test "when nothing passes, the best extraction is kept and flagged, never dropped" do
    skip_without_pdftoppm
    missing = BAC_ROWS.drop(1)
    stub_ai(:extract_pdf) { |request| statement(request.attachments.any? ? missing.drop(1) : missing) }

    with_reading_routes(vision_model) do
      outcome = reading(@bac).extract

      assert outcome.flagged?
      assert_equal :text, outcome.way, "the text layer's passed more checks"
      assert_equal 12, outcome.value[:transactions].size
    end
  end

  test "an outage on a later way keeps the extraction in hand, flagged" do
    skip_without_pdftoppm
    missing = BAC_ROWS.drop(1)
    stub_ai(:extract_pdf) do |request|
      raise Ai::Error::Upstream, "server error" if request.attachments.any?

      statement(missing)
    end

    with_reading_routes(vision_model) do
      outcome = reading(@bac).extract

      assert outcome.flagged?
      assert_equal :text, outcome.way
      assert_equal [ :text, :images ], outcome.attempts.map { _1[:way] }
      assert_equal "Upstream", outcome.attempts.last[:error]
    end
  end

  test "an outage with nothing in hand fails the reading" do
    stub_ai(:extract_pdf) { raise Ai::Error::Upstream, "server error" }

    with_reading_routes(text_model) do
      assert_raises(Ai::Error::Upstream) { reading(@bac).extract }
    end
  end

  test "pages are batched by cost with no page limit" do
    skip_without_pdftoppm
    requests = stub_ai(:extract_pdf, returns: statement([]))

    with_reading_routes(vision_model.with(batch_size: 2)) do
      reading(blank_pdf(pages: 7)).extract(read_as: :images)
    end

    assert_equal [ 2, 2, 2, 1 ], requests.map { _1.attachments.size }
    assert_equal "page-7.png", requests.last.attachments.sole.filename
  end

  test "OCR transcribes each page on its route entry, then the text model reads the transcription" do
    skip_without_pdftoppm
    transcription = "1 February Cardpayment 24.50\n4 February Payment 2,575.00"
    requests = stub_ai(:extract_pdf) do |request|
      next transcription if request.is_a?(Ai::Transport::Base::OcrRequest)

      statement([ [ "2019-02-01", -24.5 ], [ "2019-02-04", 2575.0 ] ], opening: 0.0, closing: 2550.5)
    end

    with_reading_routes(text_model, ocr_model) do
      reader = reading(@scan)
      assert_nil reader.ways[:ocr]

      outcome = reader.extract

      assert_equal :ocr, outcome.way
      assert outcome.checks.amounts_in_source, "amounts are checked against the transcription"
    end
    ocr_requests = requests.grep(Ai::Transport::Base::OcrRequest)
    assert_equal [ [ "page-1.png" ], [ "page-2.png" ] ], ocr_requests.map { _1.pages.map(&:filename) }
    assert_match "Cardpayment 24.50", requests.last.input
  end

  test "a scan's balances are read from its OCR transcription, not taken from the model" do
    skip_without_pdftoppm
    transcription = "Opening balance 0.00\n1 February Cardpayment 24.50\n4 February Payment 2,575.00\nClosing balance 2,550.50"
    stub_ai(:extract_pdf) do |request|
      next transcription if request.is_a?(Ai::Transport::Base::OcrRequest)

      statement([ [ "2019-02-01", -24.5 ], [ "2019-02-04", 2575.0 ] ], opening: 0.0, closing: 2550.5 + 24.5)
    end

    with_reading_routes(text_model, ocr_model) do
      outcome = reading(@scan).extract(read_as: :ocr)

      assert outcome.checks.reconciles, "the printed closing balance, not the model's"
      assert_equal 0.0, outcome.value[:opening_balance], "the validated balances are kept for the import"
      assert_equal 2550.5, outcome.value[:closing_balance], "not the model's 2575.0"
    end
  end

  test "a scan whose balances weren't found still tries OCR, which might read them" do
    skip_without_pdftoppm
    requests = stub_ai(:extract_pdf) do |request|
      next "1 February Cardpayment 24.50" if request.is_a?(Ai::Transport::Base::OcrRequest)

      statement(BAC_ROWS, opening: nil, closing: nil)
    end

    with_reading_routes(vision_model, ocr_model) do
      outcome = reading(@scan).extract

      assert_equal :images, outcome.way, "OCR was tried, as images had no text to show the balances aren't printed; images' extraction stays the better one"
      assert outcome.flagged?
      assert_equal [ :balances ], outcome.checks.failed
      assert_equal %i[images ocr], outcome.attempts.map { _1[:way] }
    end
    assert requests.grep(Ai::Transport::Base::OcrRequest).any?
  end

  test "read gives what the document is, from the first batch" do
    requests = stub_ai(:extract_pdf, returns: { document_type: "bank_statement", summary: "YourBank, February 2019",
                                                extracted_data: { institution_name: "YourBank", currency: "GBP" } })
    reader = reading(@bac)
    units = [ Ai::PdfReading::Unit.text("PAGE ONE", page: 1), Ai::PdfReading::Unit.text("PAGE TWO", page: 2) ]
    reader.stubs(:units_for).returns([ units, "PAGE ONE\nPAGE TWO" ])

    with_reading_routes(text_model.with(batch_size: 1)) do
      outcome = reader.read

      assert_equal "bank_statement", outcome.value[:document_type]
      assert_equal "YourBank", outcome.value.dig(:extracted_data, :institution_name)
      assert_equal :text, outcome.way
    end
    assert_match "Please analyze the following document text", requests.sole.input
    assert_includes requests.sole.input, "PAGE ONE"
    assert_not_includes requests.sole.input, "PAGE TWO"
  end

  test "pages that can't be rendered move Auto on, keeping the extraction in hand" do
    wrong = BAC_ROWS.map { |date, amount| [ date, -amount ] }
    stub_ai(:extract_pdf, returns: statement(wrong))
    Pdf::PageImages.stubs(:render).raises(Pdf::PageImages::Error.new("pdftoppm is not installed (poppler-utils)", code: :missing_binary))

    with_reading_routes(vision_model) do
      outcome = reading(@bac).extract

      assert_equal :text, outcome.way
      assert outcome.flagged?
      assert_equal :missing_binary, outcome.attempts.last[:render_error]
    end
  end

  test "a later page that can't be rendered keeps the earlier batches, incomplete" do
    Pdf::PageImages.stubs(:page_count).returns(2)
    Pdf::PageImages.stubs(:render).with(anything, pages: [ 1 ]).returns([ "png" ])
    Pdf::PageImages.stubs(:render).with(anything, pages: [ 2 ]).raises(Pdf::PageImages::Error.new("page 2 would be 400 million pixels", code: :too_large))
    stub_ai(:extract_pdf, returns: statement(BAC_ROWS))
    one_page = vision_model.with(batch_size: 1)

    with_reading_routes(one_page) do
      outcome = reading(@bac).extract(read_as: :images)

      assert_equal :images, outcome.way
      assert_equal BAC_ROWS.size, outcome.value[:transactions].size
      assert_equal false, outcome.checks.complete
    end
  end

  test "a page no route can fit is skipped and logged, and the extraction is incomplete" do
    units = [ Ai::PdfReading::Unit.text("PAGE ONE 24.50", page: 1), Ai::PdfReading::Unit.text("PAGE TWO #{"x" * 50}", page: 2) ]
    stub_ai(:extract_pdf) do |request|
      raise Ai::Error::ContextTooLong, "too long" if request.input.include?("PAGE TWO")

      statement([ [ "2019-02-01", -24.5 ] ])
    end

    with_reading_routes(text_model.with(batch_size: 1)) do
      result = Ai::Generations::ExtractBankStatement.new(units:, content: "", family: @family).call

      assert result.success?
      assert_equal [ units.last ], result.skipped
      assert_equal [ "text:2-2" ], DebugLogEntry.where(category: "ai_generation").last.metadata["item_ids"]
    end
  end

  test "read goes past a cover page that says nothing, until a batch says it's a statement" do
    units = [ Ai::PdfReading::Unit.text("COVER", page: 1), Ai::PdfReading::Unit.text("TRANSACTIONS", page: 2) ]
    stub_ai(:extract_pdf) do |request|
      request.input.include?("COVER") ? { document_type: "other", summary: nil, extracted_data: nil } : { document_type: "bank_statement", summary: "YourBank", extracted_data: nil }
    end
    reader = reading(@bac)
    reader.stubs(:units_for).returns([ units, "COVER\nTRANSACTIONS" ])

    with_reading_routes(text_model.with(batch_size: 1)) do
      assert_equal "bank_statement", reader.read.value[:document_type]
    end
  end

  test "read keeps the first answer when a lookahead batch cannot render" do
    units = [ Ai::PdfReading::Unit.text("COVER", page: 1), Ai::PdfReading::Unit.text("TRANSACTIONS", page: 2) ]
    first = Ai::Result.new(value: { document_type: "other", summary: nil, extracted_data: nil }, remaining: [ units.last ])
    failing = stub
    failing.stubs(:call).raises(Pdf::PageImages::Error.new("render failed", code: :unreadable))
    Ai::Generations::ReadPdf.stubs(:new).returns(stub(call: first), failing)
    reader = reading(@bac)
    reader.stubs(:units_for).returns([ units, "COVER\nTRANSACTIONS" ])

    with_reading_routes(text_model.with(batch_size: 1)) do
      assert_equal "other", reader.read.value[:document_type]
    end
  end

  test "a page-local render failure leaves that page untranscribed and keeps the others" do
    reader = reading(@scan)
    Pdf::PageImages.stubs(:page_count).returns(3)
    Pdf::PageImages.stubs(:render).with(@scan, pages: [ 1 ]).returns([ "page-1" ])
    Pdf::PageImages.stubs(:render).with(@scan, pages: [ 2 ])
                                  .raises(Pdf::PageImages::Error.new("page too large", code: :too_large))
    Pdf::PageImages.stubs(:render).with(@scan, pages: [ 3 ]).returns([ "page-3" ])
    stub_ai(:extract_pdf) do |request|
      "text from #{request.pages.first.filename}"
    end

    with_reading_routes(text_model, ocr_model) do
      transcription = reader.send(:transcribe)

      assert_equal [ "text from page-1.png", "", "text from page-3.png" ], transcription.pages
      assert_equal [ 2 ], transcription.untranscribed_pages
    end
  end

  test "a page-count failure keeps the unreadable reason for Images but not for Text on a scan" do
    stub_ai(:extract_pdf)
    Pdf::PageImages.stubs(:page_count).raises(Pdf::PageImages::Error.new("PDF does not contain EOF marker", code: :unreadable))

    with_reading_routes(vision_model, text_model) do
      error = assert_raises(Ai::Error::Unavailable) { reading(@scan).read(read_as: :images) }

      assert_equal :unreadable, error.reason
      assert_equal :unreadable, error.code
    end

    Pdf::PageImages.unstub(:page_count)
    with_reading_routes(text_model) do
      error = assert_raises(Ai::Error::Unavailable) { reading(@scan).read(read_as: :text) }

      assert_equal :no_text_layer, error.reason
    end
  end

  test "an OCR route marked down after the check ends that way before any page is rendered" do
    reader = reading(@scan)
    reader.stubs(:ocr_route).returns(nil)
    Pdf::PageImages.expects(:render).never

    assert_raises(Ai::Error::Unavailable) { reader.send(:transcribe) }
  end

  test "two OCR routes fail over a page, cache the transcription, and flag pages neither read" do
    skip_without_pdftoppm
    calls = []
    requests = stub_ai(:extract_pdf) do |request|
      case request
      when Ai::Transport::Base::OcrRequest
        page = request.pages.first.filename
        calls << [ request.model.name, page ]
        raise Ai::Error::UnsupportedInput, "image input is not supported" if request.model.name == "unlimited-ocr-2" && page == "page-1.png"
        raise Ai::Error::UnsupportedInput, "image input is not supported" if page == "page-3.png"

        "1 February Cardpayment 24.50"
      else
        next { document_type: "bank_statement", summary: nil, extracted_data: nil } if request.schema_name == "document_analysis"

        statement([ [ "2019-02-01", -24.5 ] ], opening: 0.0, closing: 24.5)
      end
    end

    with_reading_routes(text_model, ocr_model, backup_ocr_model) do
      reader = reading(blank_pdf(pages: 3))
      reader.read(read_as: :ocr)
      outcome = reader.extract(read_as: :ocr)

      assert_equal :ocr, outcome.way
      assert_equal false, outcome.checks.complete, "page 3 had no transcription"
      assert_includes outcome.checks.failed, :complete
    end

    assert_equal [
      [ "unlimited-ocr-2", "page-1.png" ], [ "parse-v5.0", "page-1.png" ],
      [ "unlimited-ocr-2", "page-2.png" ],
      [ "unlimited-ocr-2", "page-3.png" ], [ "parse-v5.0", "page-3.png" ]
    ], calls, "classification and extraction share one transcription"
    assert_equal 5, requests.grep(Ai::Transport::Base::OcrRequest).size
  end

  test "an OCR timeout fails over to the backup route instead of ending the way" do
    skip_without_pdftoppm
    calls = []
    stub_ai(:extract_pdf) do |request|
      if request.is_a?(Ai::Transport::Base::OcrRequest)
        calls << request.model.name
        raise Ai::Error::Timeout, "slow" if request.model.name == "unlimited-ocr-2"

        "1 February Cardpayment 24.50"
      else
        next { document_type: "bank_statement", summary: nil, extracted_data: nil } if request.schema_name == "document_analysis"

        statement([ [ "2019-02-01", -24.5 ] ], opening: 0.0, closing: 24.5)
      end
    end

    with_reading_routes(text_model, ocr_model, backup_ocr_model) do
      outcome = reading(blank_pdf(pages: 1)).extract(read_as: :ocr)

      assert_equal :ocr, outcome.way
      assert outcome.value.present?, "the backup OCR route produced the reading"
    end
    assert_equal %w[unlimited-ocr-2 parse-v5.0], calls, "the timeout ended this route's try, not the OCR way"
  end

  test "a timed-out OCR route is skipped on later pages" do
    skip_without_pdftoppm
    calls = []
    stub_ai(:extract_pdf) do |request|
      if request.is_a?(Ai::Transport::Base::OcrRequest)
        page = request.pages.first.filename
        calls << [ request.model.name, page ]
        raise Ai::Error::Timeout, "slow" if request.model.name == "unlimited-ocr-2"

        "1 February Cardpayment 24.50"
      else
        next { document_type: "bank_statement", summary: nil, extracted_data: nil } if request.schema_name == "document_analysis"

        statement([ [ "2019-02-01", -24.5 ] ], opening: 0.0, closing: 24.5)
      end
    end

    with_reading_routes(text_model, ocr_model, backup_ocr_model) do
      reading(blank_pdf(pages: 2)).extract(read_as: :ocr)
    end

    assert_equal [ [ "unlimited-ocr-2", "page-1.png" ], [ "parse-v5.0", "page-1.png" ],
                   [ "parse-v5.0", "page-2.png" ] ], calls
  end

  test "an OCR failover logs the class and status, never the provider's message" do
    skip_without_pdftoppm
    warnings = []
    Rails.logger.stubs(:warn).with { |message| warnings << message; true }
    stub_ai(:extract_pdf) do |request|
      if request.is_a?(Ai::Transport::Base::OcrRequest)
        raise Ai::Error::Refused.new("400: account 12345678 is invalid", status: 400) if request.model.name == "unlimited-ocr-2"

        "1 February Cardpayment 24.50"
      else
        next { document_type: "bank_statement", summary: nil, extracted_data: nil } if request.schema_name == "document_analysis"

        statement([ [ "2019-02-01", -24.5 ] ], opening: 0.0, closing: 24.5)
      end
    end

    with_reading_routes(text_model, ocr_model, backup_ocr_model) do
      assert_equal :ocr, reading(blank_pdf(pages: 1)).extract(read_as: :ocr).way
    end

    warning = warnings.find { _1.include?("unlimited-ocr-2") }
    assert warning, "the failed route must still be logged"
    assert_includes warning, "Ai::Error::Refused"
    assert_includes warning, "status=400"
    assert_not_includes warning, "12345678"
  end

  test "OCR checks cancellation between pages" do
    skip_without_pdftoppm
    checks = 0
    requests = stub_ai(:extract_pdf, returns: "a page")

    with_reading_routes(text_model, ocr_model) do
      reader = reading(@scan)
      error = assert_raises(Ai::Error::Cancelled) do
        reader.send(:transcribe, cancelled: -> { (checks += 1) == 3 })
      end

      assert_equal "cancelled", error.message
    end
    assert_equal 1, requests.grep(Ai::Transport::Base::OcrRequest).size
  end

  test "OCR pages no route can read are an empty text layer, not an error" do
    skip_without_pdftoppm
    stub_ai(:extract_pdf) { raise Ai::Error::UnsupportedInput, "image input is not supported" }

    with_reading_routes(text_model, ocr_model) do
      error = assert_raises(Ai::Error::Unavailable) { reading(@scan).extract(read_as: :ocr) }

      assert_equal :no_text_layer, error.reason
    end
  end

  test "a scan nothing can render keeps the renderer's code on the unavailable error" do
    stub_ai(:extract_pdf)
    Pdf::PageImages.stubs(:render).raises(Pdf::PageImages::Error.new("pdftoppm is not installed (poppler-utils)", code: :missing_binary))

    with_reading_routes(vision_model) do
      error = assert_raises(Ai::Error::Unavailable) { reading(@scan).extract }

      assert_equal :missing_binary, error.code
    end
  end

  private
    def reading(content) = Ai::PdfReading.new(content:, family: @family, filename: "statement.pdf")

    def statement(rows, opening: 40_000.0, closing: 44_079.83)
      { bank_name: "YourBank", account_holder: nil, account_number: nil, currency: "GBP", opening_balance: opening, closing_balance: closing,
        statement_period: { start_date: "2019-02-01", end_date: "2019-03-01" },
        transactions: rows.map { |date, amount| { date:, description: "row", amount:, reference: nil, category: nil } } }
    end

    def text_model = AiTestHelper.test_config.models.find { _1.name == "qwen3-8b" }

    def vision_model
      endpoint = Ai::Config::Endpoint.new(name: :vision, protocol: :compatible, base_url: "http://vision.local:8080/v1", location: :local)
      Ai::Config::Model.new(endpoint:, name: "qwen3-vl", capabilities: %i[structured_output vision], context_window: 32_000)
    end

    def ocr_model
      endpoint = Ai::Config::Endpoint.new(name: :ocr, protocol: :compatible, base_url: "http://ocr.local:8080/v1", location: :local)
      Ai::Config::Model.new(endpoint:, name: "unlimited-ocr-2", capabilities: %i[ocr vision], ocr_prompt: "unlimited_ocr_2")
    end

    def backup_ocr_model
      endpoint = Ai::Config::Endpoint.new(name: :ocr_backup, protocol: :compatible, base_url: "http://ocr-backup.local:8080/v1", location: :local)
      Ai::Config::Model.new(endpoint:, name: "parse-v5.0", capabilities: %i[ocr vision], ocr_prompt: "markdown")
    end

    def with_reading_routes(*models, &block)
      names = models.map { "#{_1.endpoint.name}/#{_1.name}" }
      Ai::Config.with(AiTestHelper.build_ai_config(models, { extract_pdf: names }), &block)
    end

    def skip_without_pdftoppm
      skip "pdftoppm isn't installed (poppler-utils)" unless system("pdftoppm", "-v", out: File::NULL, err: File::NULL)
    end

    def blank_pdf(pages:)
      objects = [ "<< /Type /Catalog /Pages 2 0 R >>",
                  "<< /Type /Pages /Kids [#{(0...pages).map { "#{3 + _1} 0 R" }.join(" ")}] /Count #{pages} >>" ] +
                Array.new(pages) { "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>" }
      pdf = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map { |object, i| pdf.bytesize.tap { pdf << "#{i + 1} 0 obj\n#{object}\nendobj\n" } }
      xref = pdf.bytesize
      pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n" << offsets.map { format("%010d 00000 n \n", _1) }.join
      pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    end
end
