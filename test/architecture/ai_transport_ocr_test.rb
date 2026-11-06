require "test_helper"

# The `ocr` half of the transport contract (section 8.1, 2e): a local OCR model read through
# chat with its own prompt folder, and Mistral and Cohere through RubyLLM.ocr, one page image per
# request. Stubbed through WebMock: Mistral and Cohere are untested live until someone records
# test/models/ai/live/ocr_live_test.rb with a key (2e plan, decision 2).
class AiTransportOcrTest < ActiveSupport::TestCase
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  CHAT_URL = "http://ocr.local:8080/v1/chat/completions".freeze
  PNG = "\x89PNG\r\n\x1a\n#{"\0" * 32}".b.freeze

  setup do
    @pages = [ Ai::Attachment.png(PNG, filename: "page-1.png"), Ai::Attachment.png(PNG, filename: "page-2.png") ]
    Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
  end

  test "a general vision model gets one message: the Markdown instruction and every page" do
    bodies = stub_json(CHAT_URL, chat_answer("| Date | Amount |\n| 1 Feb | 24.50 |"))

    response = ocr(local_model(ocr_prompt: "markdown"))

    messages = bodies.first["messages"]
    assert_equal 1, messages.size
    assert_equal %w[text image_url image_url], messages.first["content"].map { _1["type"] }
    assert_match(/Transcribe every page/, messages.first["content"].first["text"])
    assert_equal [ "| Date | Amount |\n| 1 Feb | 24.50 |" ], response.texts
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

  test "Mistral reads one page image per request through RubyLLM.ocr" do
    bodies = stub_json("https://api.mistral.ai/v1/ocr", { model: "mistral-ocr-latest", pages: [ { index: 0, markdown: "BAC statement" } ],
                                                          usage_info: { pages_processed: 1 } })
    endpoint = ai_endpoint(name: "mistral", preset: :mistral, base_url: nil)

    response = ocr(ai_model(name: "mistral-ocr-latest", endpoint:, capabilities: %i[ocr]))

    assert_equal 2, bodies.size
    assert_equal "image_url", bodies.first.dig("document", "type")
    assert bodies.first.dig("document", "image_url").start_with?("data:image/png;base64,")
    assert_equal [ "BAC statement", "BAC statement" ], response.texts
    assert_requested(:post, "https://api.mistral.ai/v1/ocr", headers: { "Authorization" => "Bearer test-key" }, times: 2)
  end

  test "Cohere reads one page image per request as Markdown" do
    bodies = stub_json("https://api.cohere.com/v2/parse", { pages: [ { index: 0, markdown: { content: "Impact page" } } ],
                                                            meta: { billed_units: { pages: 1 } } })
    endpoint = ai_endpoint(name: "cohere", preset: :cohere, base_url: nil)

    response = ocr(ai_model(name: "cohere-parse", endpoint:, capabilities: %i[ocr]))

    assert_equal %w[markdown markdown], bodies.map { _1["output_format"] }
    assert_equal [ "Impact page", "Impact page" ], response.texts
  end

  test "a model without ocr, or a PDF instead of pages, is refused before anything is sent" do
    stub = stub_request(:post, CHAT_URL)

    assert_raises(Ai::Error::Refused) { ocr(local_model.with(capabilities: %w[vision])) }
    assert_raises(Ai::Error::Refused) { ocr(local_model, pages: [ Ai::Attachment.pdf("%PDF-1.4") ]) }
    assert_not_requested stub
  end

  test "one ocr.ai event per call, naming the pages without their bytes or the transcription" do
    stub_json(CHAT_URL, chat_answer("ACME PAYROLL 2,500.00"))

    events = capture_ai_events { ocr(local_model) }

    payload = events.sole.payload
    assert_equal "ocr.ai", events.sole.name
    assert_equal [ "page-1.png", "page-2.png" ], payload[:request][:attachments].map { _1[:filename] }
    assert_equal({ texts: 1, characters: 21 }, payload[:output])
    assert_not_includes payload.to_s, "ACME"
  end

  test "an unknown OCR prompt is a configuration error" do
    assert_raises(ArgumentError) { local_model(ocr_prompt: "made_up") }
  end

  private
    def local_model(ocr_prompt: "markdown")
      endpoint = ai_endpoint(name: "ocr", base_url: "http://ocr.local:8080/v1", location: :local)
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
