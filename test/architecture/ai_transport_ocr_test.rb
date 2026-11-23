require "test_helper"

# The `ocr` half of the transport contract: a local OCR model read through
# chat with its own prompt folder, and Mistral and Cohere through RubyLLM.ocr, one page image per
# request. Stubbed through WebMock: Mistral and Cohere are untested live until someone records
# test/models/ai/live/ocr_live_test.rb with a key.
class AiTransportOcrTest < ActiveSupport::TestCase
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  CHAT_URL = "http://ocr.local:8080/v1/chat/completions".freeze
  PNG = "\x89PNG\r\n\x1a\n#{"\0" * 32}".b.freeze

  setup do
    @pages = [ Ai::Attachment.png(PNG, filename: "page-1.png"), Ai::Attachment.png(PNG, filename: "page-2.png") ]
    Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
  end

  test "Unlimited-OCR-2 gets a <PAGE> message per page, then the instruction, and leaked special tokens go" do
    bodies = stub_json(CHAT_URL, chat_answer("<table><tr><td>24.50</td></tr></table><｜end▁of▁sentence｜>"))

    response = ocr(local_model(ocr_prompt: "unlimited_ocr_2"))

    messages = bodies.first["messages"]
    assert_equal 3, messages.size
    assert_equal [ "<PAGE>", "<PAGE>" ], messages.first(2).map { _1["content"].first["text"] }
    assert_equal [ "image_url" ], messages.first["content"].drop(1).map { _1["type"] }
    assert_equal "Multi page parsing.", messages.last["content"]
    assert_equal "<table><tr><td>24.50</td></tr></table>", response.text
  end

  test "Cohere reads one page image per request as Markdown" do
    bodies = stub_json("https://api.cohere.com/v2/parse", { pages: [ { index: 0, markdown: { content: "Impact page" } } ],
                                                            meta: { billed_units: { pages: 1 } } })
    endpoint = ai_endpoint(name: "cohere", preset: :cohere, base_url: nil)

    response = ocr(ai_model(name: "parse-v5.0", endpoint:, capabilities: %i[ocr]))

    assert_equal %w[markdown markdown], bodies.map { _1["output_format"] }
    assert_equal [ "Impact page", "Impact page" ], response.texts
  end

  test "a transcription cut at the output limit is unusable, so Auto reads another way" do
    stub_json(CHAT_URL, chat_answer("| Date | Amount |\n| 1 Feb | 24.50 |").tap { _1[:choices].first[:finish_reason] = "length" })

    assert_raises(Ai::Error::InvalidOutput) { ocr(local_model(ocr_prompt: "markdown")) }
  end

  test "an endpoint that needs static headers refuses native OCR before sending the page" do
    endpoint = ai_endpoint(name: "mistral", preset: :mistral, base_url: nil, extra_headers: { "X-Gateway-Key" => "secret" })
    model = ai_model(name: "mistral-ocr-latest", endpoint:, capabilities: %i[ocr])
    stub = stub_request(:post, "https://api.mistral.ai/v1/ocr")

    assert_raises(Ai::Error::Refused) { ocr(model, pages: @pages.first(1)) }
    assert_not_requested stub
  end

  test "a native OCR answer for another page, or without Markdown, is InvalidOutput" do
    endpoint = ai_endpoint(name: "mistral", preset: :mistral, base_url: nil)
    model = ai_model(name: "mistral-ocr-latest", endpoint:, capabilities: %i[ocr])
    stub_json("https://api.mistral.ai/v1/ocr", { model: model.name, pages: [ { index: 1, markdown: "another page" } ] })

    assert_raises(Ai::Error::InvalidOutput) { ocr(model, pages: @pages.first(1)) }
  end

  test "a malformed Cohere OCR answer is InvalidOutput, not text for the generation" do
    endpoint = ai_endpoint(name: "cohere", preset: :cohere, base_url: nil)
    model = ai_model(name: "parse-v5.0", endpoint:, capabilities: %i[ocr])
    stub_json("https://api.cohere.com/v2/parse", { pages: [ { index: 0, markdown: { content: 42 } } ],
                                                    meta: { billed_units: { pages: 1 } } })

    assert_raises(Ai::Error::InvalidOutput) { ocr(model, pages: @pages.first(1)) }
  end

  test "a retried chat OCR request gets only the time left in the call's budget" do
    clock = [ 0.0 ]
    stub_request(:post, CHAT_URL).to_return(
      lambda { |_| clock[0] += 45; { status: 503, headers: JSON_HEADERS, body: { error: { message: "busy" } }.to_json } },
      { status: 200, headers: JSON_HEADERS, body: chat_answer("ACME PAYROLL 2,500.00").to_json }
    )
    timeouts = []
    context = RubyLLM.method(:context)
    recording = ->(&configure) { context.call { |config| configure.call(config).tap { timeouts << config.request_timeout } } }

    Ai::CallContext.stub(:now, -> { clock[0] }) do
      RubyLLM.stub(:context, recording) { ocr(local_model(max_retries: 1), pages: @pages.first(1)) }
    end

    assert_equal [ 60, 15 ], timeouts.map(&:round)
  end

  test "a retried native OCR request gets only the time left in the call's budget" do
    clock = [ 0.0 ]
    url = "https://api.mistral.ai/v1/ocr"
    stub_request(:post, url).to_return(
      lambda { |_| clock[0] += 45; { status: 503, headers: JSON_HEADERS, body: { error: { message: "busy" } }.to_json } },
      { status: 200, headers: JSON_HEADERS,
        body: { model: "mistral-ocr-latest", pages: [ { index: 0, markdown: "BAC statement" } ] }.to_json }
    )
    endpoint = ai_endpoint(name: "mistral", preset: :mistral, base_url: nil, max_retries: 1)
    model = ai_model(name: "mistral-ocr-latest", endpoint:, capabilities: %i[ocr])
    timeouts = []
    context = RubyLLM.method(:context)
    recording = ->(&configure) { context.call { |config| configure.call(config).tap { timeouts << config.request_timeout } } }

    Ai::CallContext.stub(:now, -> { clock[0] }) do
      RubyLLM.stub(:context, recording) { ocr(model, pages: @pages.first(1)) }
    end

    assert_equal [ 60, 15 ], timeouts.map(&:round)
  end

  private
    def local_model(ocr_prompt: "markdown", max_retries: 0)
      endpoint = ai_endpoint(name: "ocr", base_url: "http://ocr.local:8080/v1", location: :local, max_retries:)
      ai_model(name: "unlimited-ocr-2", endpoint:, capabilities: %i[ocr vision], ocr_prompt:)
    end

    def ocr(model, pages: @pages)
      request = Ai::Transport::Base::OcrRequest.new(feature: :extract_pdf, model:, pages:)
      Ai::Transport.for(model.endpoint).ocr(request)
    end

    def stub_json(url, body)
      bodies = []
      stub_request(:post, url).to_return(lambda do |request|
        bodies << JSON.parse(request.body)
        { status: 200, headers: JSON_HEADERS, body: body.to_json }
      end)
      bodies
    end

    def chat_answer(content)
      { id: "c1", model: "unlimited-ocr-2", choices: [ { index: 0, message: { role: "assistant", content: }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 1200, completion_tokens: 40, total_tokens: 1240 } }
    end
end
