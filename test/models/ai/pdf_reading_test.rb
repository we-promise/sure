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

  test "an outage with nothing in hand fails the reading, so the job's retries apply" do
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

  test "read gives what the document is, from the first batch" do
    requests = stub_ai(:extract_pdf, returns: { document_type: "bank_statement", summary: "YourBank, February 2019",
                                                extracted_data: { institution_name: "YourBank", currency: "GBP" } })

    with_reading_routes(text_model) do
      outcome = reading(@bac).read

      assert_equal "bank_statement", outcome.value[:document_type]
      assert_equal "YourBank", outcome.value.dig(:extracted_data, :institution_name)
      assert_equal :text, outcome.way
    end
    assert_match "Please analyze the following document text", requests.sole.input
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
