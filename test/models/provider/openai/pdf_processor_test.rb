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

  test "GPT-6 Sol PDF vision uses the completion token budget" do
    client = mock
    client.expects(:chat).with do |request|
      params = request[:parameters]
      params[:model] == "gpt-6-sol" &&
        params[:max_completion_tokens] == 8192 &&
        !params.key?(:max_tokens)
    end.returns(
      "choices" => [ { "message" => { "content" => {
        document_type: "other", summary: "Synthetic PDF", extracted_data: {}
      }.to_json } } ],
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30 }
    )
    processor = Provider::Openai::PdfProcessor.new(
      client,
      model: "gpt-6-sol",
      pdf_content: @pdf_content,
      max_response_tokens: 8192,
      processing_mode: :vision
    )
    processor.stubs(:convert_pdf_to_images).returns([ "synthetic-image" ])

    assert_equal "Synthetic PDF", processor.process.summary
  end

  test "GPT-6 Sol PDF text extraction preserves the existing uncapped request" do
    client = mock
    client.expects(:chat).with do |request|
      params = request[:parameters]
      params[:model] == "gpt-6-sol" &&
        !params.key?(:max_completion_tokens) && !params.key?(:max_tokens)
    end.returns(
      "choices" => [ { "message" => { "content" => {
        document_type: "other", summary: "Synthetic text", extracted_data: {}
      }.to_json } } ],
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30 }
    )
    processor = Provider::Openai::PdfProcessor.new(
      client,
      model: "gpt-6-sol",
      pdf_content: @pdf_content,
      max_response_tokens: 8192,
      processing_mode: :text
    )
    processor.stubs(:extract_text_from_pdf).returns("Synthetic statement")

    assert_equal "Synthetic text", processor.process.summary
  end

  test "GPT-6 Sol PDF vision omits an unconfigured completion limit" do
    processor = vision_processor(model: "gpt-6-sol", max_response_tokens: nil)
    expect_vision_request(processor, model: "gpt-6-sol") do |params|
      !params.key?(:max_tokens) && !params.key?(:max_completion_tokens)
    end

    assert_equal "Synthetic PDF", processor.process.summary
  end

  test "native o-series PDF vision uses completion limits when configured" do
    %w[o1 o3].each do |model|
      processor = vision_processor(model: model, max_response_tokens: 8192)
      expect_vision_request(processor, model: model) do |params|
        params[:max_completion_tokens] == 8192 && !params.key?(:max_tokens)
      end

      assert_equal "Synthetic PDF", processor.process.summary
    end
  end

  test "native o-series PDF vision omits unconfigured completion limits" do
    %w[o1 o3].each do |model|
      processor = vision_processor(model: model, max_response_tokens: nil)
      expect_vision_request(processor, model: model) do |params|
        !params.key?(:max_tokens) && !params.key?(:max_completion_tokens)
      end

      assert_equal "Synthetic PDF", processor.process.summary
    end
  end

  test "legacy OpenAI PDF vision retains max_tokens" do
    processor = vision_processor(model: "gpt-4.1", max_response_tokens: 512)
    expect_vision_request(processor, model: "gpt-4.1") do |params|
      params[:max_tokens] == 512 && !params.key?(:max_completion_tokens)
    end

    assert_equal "Synthetic PDF", processor.process.summary
  end

  test "custom provider PDF vision retains max_tokens even with a GPT-6 model name" do
    processor = vision_processor(model: "gpt-6-sol", max_response_tokens: 512, custom_provider: true)
    expect_vision_request(processor, model: "gpt-6-sol") do |params|
      params[:max_tokens] == 512 && !params.key?(:max_completion_tokens)
    end

    assert_equal "Synthetic PDF", processor.process.summary
  end

  test "custom provider PDF vision retains max_tokens with an o-series model name" do
    processor = vision_processor(model: "o3", max_response_tokens: 512, custom_provider: true)
    expect_vision_request(processor, model: "o3") do |params|
      params[:max_tokens] == 512 && !params.key?(:max_completion_tokens)
    end

    assert_equal "Synthetic PDF", processor.process.summary
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
    # Build a vision processor with synthetic images and a mocked API client.
    # @return [Provider::Openai::PdfProcessor] processor under test
    def vision_processor(model:, max_response_tokens:, custom_provider: false)
      processor = Provider::Openai::PdfProcessor.new(
        mock,
        model: model,
        pdf_content: @pdf_content,
        max_response_tokens: max_response_tokens,
        custom_provider: custom_provider,
        processing_mode: :vision
      )
      processor.stubs(:convert_pdf_to_images).returns([ "synthetic-image" ])
      processor
    end

    # Check the emitted API payload and return a synthetic document response.
    # @yieldparam params [Hash] outbound Chat Completions parameters
    def expect_vision_request(processor, model:)
      processor.client.expects(:chat).with do |request|
        params = request[:parameters]
        params[:model] == model && yield(params)
      end.returns(
        "choices" => [ { "message" => { "content" => {
          document_type: "other", summary: "Synthetic PDF", extracted_data: {}
        }.to_json } } ],
        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30 }
      )
    end

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
