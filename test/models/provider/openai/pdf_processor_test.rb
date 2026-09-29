require "test_helper"

class Provider::Openai::PdfProcessorTest < ActiveSupport::TestCase
  setup do
    @pdf_content = "%PDF-1.4 fake bytes".b
  end

  test "extracts only allowlisted error fields into span output when the API call fails" do
    error = StandardError.new("boom")
    def error.response_body
      {
        "error" => { "type" => "invalid_request_error", "message" => "invalid request", "code" => "bad_pdf" },
        "request" => { "messages" => "statement text that should never leak" }
      }
    end
    def error.response_headers
      { "x-request-id" => "req_abc123" }
    end

    captured_output = nil
    trace = stub_trace { |output| captured_output = output }

    assert_raises(StandardError) do
      build_processor(error, trace).process
    end

    assert_equal(
      { type: "invalid_request_error", message: "invalid request", code: "bad_pdf", request_id: "req_abc123" },
      captured_output[:error_detail]
    )
  end

  test "error_detail is nil in span output when the error exposes no response_body" do
    error = StandardError.new("boom")

    captured_output = nil
    trace = stub_trace { |output| captured_output = output }

    assert_raises(StandardError) do
      build_processor(error, trace).process
    end

    assert_nil captured_output[:error_detail]
  end

  test "error_detail falls back to a placeholder when reading response_body itself raises" do
    error = StandardError.new("boom")
    def error.response_body
      raise "response_body accessor exploded"
    end

    captured_output = nil
    trace = stub_trace { |output| captured_output = output }

    assert_raises(StandardError) do
      build_processor(error, trace).process
    end

    assert_match(/detail unavailable/i, captured_output[:error_detail])
  end

  test "text mode exercises only text extraction" do
    expected = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Synthetic PDF",
      document_type: "other",
      extracted_data: {}
    )
    processor = Provider::Openai::PdfProcessor.new(
      mock,
      model: "gpt-4.1",
      pdf_content: @pdf_content,
      max_response_tokens: 512,
      processing_mode: :text
    )
    processor.expects(:process_with_text_extraction).returns(expected)
    processor.expects(:process_with_vision).never

    assert_equal expected, processor.process
  end

  test "vision mode exercises only vision processing" do
    expected = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Synthetic PDF",
      document_type: "other",
      extracted_data: {}
    )
    processor = Provider::Openai::PdfProcessor.new(
      mock,
      model: "gpt-4.1",
      pdf_content: @pdf_content,
      max_response_tokens: 512,
      processing_mode: :vision
    )
    processor.expects(:process_with_text_extraction).never
    processor.expects(:process_with_vision).returns(expected)

    assert_equal expected, processor.process
  end

  test "convert_pdf_to_images raises a coded error when the pdftoppm binary is missing" do
    processor = Provider::Openai::PdfProcessor.new(
      mock,
      model: "gpt-4.1",
      pdf_content: @pdf_content,
      max_response_tokens: 512,
      processing_mode: :vision
    )

    # Simulate poppler-utils not being installed: Kernel#system returns `nil`
    # (the executable cannot be started) rather than `false`.
    processor.stubs(:system).returns(nil)

    error = assert_raises(Provider::Openai::Error) do
      processor.send(:convert_pdf_to_images)
    end

    assert_equal :render_missing_binary, error.failure_code
    assert_match(/poppler-utils/, error.message)
  end

  test "convert_pdf_to_images still degrades to [] when pdftoppm is present but rejects the PDF" do
    Rails.logger.stubs(:error)
    processor = Provider::Openai::PdfProcessor.new(
      mock,
      model: "gpt-4.1",
      pdf_content: @pdf_content,
      max_response_tokens: 512,
      processing_mode: :vision
    )

    # Binary is installed, but pdftoppm exits non-zero on bad input (system
    # returns `false`): keep the pre-existing "return no pages" behavior (no
    # coded error).
    processor.stubs(:system).returns(false)

    assert_equal [], processor.send(:convert_pdf_to_images)
  end

  private
    def build_processor(error, trace)
      client = mock
      client.expects(:chat).raises(error)

      processor = Provider::Openai::PdfProcessor.new(
        client,
        model: "gpt-4.1",
        pdf_content: @pdf_content,
        langfuse_trace: trace,
        max_response_tokens: 1000
      )
      processor.stubs(:extract_text_from_pdf).returns("Statement text")
      processor
    end

    def stub_trace
      span = mock
      span.expects(:end).with { |args| yield(args[:output]); true }
      trace = mock
      trace.stubs(:span).returns(span)
      trace
    end
end
