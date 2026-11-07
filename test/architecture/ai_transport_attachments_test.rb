require "test_helper"

# Files on `generate` (section 7, 2e): what each transport sends for a PDF and for page images,
# the capability check before anything is sent, the preset's PDF limit, and that a `.ai` event
# names files without their bytes. Stubbed through WebMock.
class AiTransportAttachmentsTest < ActiveSupport::TestCase
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  CHAT_URL = "https://llm.example.test/v1/chat/completions".freeze
  RESPONSES_URL = "https://api.openai.example.test/v1/responses".freeze
  MESSAGES_URL = "https://anthropic.example.test/v1/messages".freeze
  SCHEMA = { type: "object", properties: { ok: { type: "boolean" } }, required: %w[ok], additionalProperties: false }.freeze
  PNG = "\x89PNG\r\n\x1a\n#{"\0" * 32}".b.freeze
  PDF = "%PDF-1.4\n#{"x" * 64}\n%%EOF".b.freeze

  test "page images go to a compatible server as image parts at high detail, after the input" do
    bodies = stub_json(CHAT_URL, chat_answer)

    generate(attachments: [ Ai::Attachment.png(PNG, filename: "page-1.png"), Ai::Attachment.png(PNG, filename: "page-2.png") ],
             capabilities: %i[structured_output vision])

    content = bodies.first["messages"].last["content"]
    assert_equal %w[text image_url image_url], content.map { _1["type"] }
    assert_equal %w[high high], content.drop(1).map { _1.dig("image_url", "detail") }
    assert content[1].dig("image_url", "url").start_with?("data:image/png;base64,")
  end

  test "a PDF goes to OpenAI's Responses API as an input file" do
    bodies = stub_json(RESPONSES_URL, responses_answer)
    endpoint = ai_endpoint(name: "openai", base_url: "https://api.openai.example.test/v1", preset: :openai, responses_api: true)

    generate(endpoint:, attachments: [ Ai::Attachment.pdf(PDF, filename: "statement.pdf") ],
             capabilities: %i[structured_output documents])

    part = bodies.first["input"].last["content"].find { _1["type"] == "input_file" }
    assert_equal "statement.pdf", part["filename"]
    assert part["file_data"].start_with?("data:application/pdf;base64,")
  end

  test "a PDF goes to Anthropic as a base64 document block, and pages as image blocks" do
    bodies = stub_json(MESSAGES_URL, anthropic_answer)
    endpoint = ai_endpoint(name: "anthropic", protocol: :anthropic, base_url: "https://anthropic.example.test")

    generate(endpoint:, capabilities: %i[structured_output documents vision],
             attachments: [ Ai::Attachment.pdf(PDF, filename: "statement.pdf"), Ai::Attachment.png(PNG, filename: "page-1.png") ])

    content = bodies.first["messages"].last["content"]
    assert_equal %w[text document image], content.map { _1["type"] }
    assert_equal "application/pdf", content[1].dig("source", "media_type")
    assert_equal "base64", content[1].dig("source", "type")
  end

  test "images to a model without vision are refused before anything is sent" do
    stub = stub_request(:post, CHAT_URL)

    error = assert_raises(Ai::Error::Refused) do
      generate(attachments: [ Ai::Attachment.png(PNG, filename: "page-1.png") ], capabilities: %i[structured_output])
    end

    assert_match(/needs vision/, error.message)
    assert_not_requested stub
  end

  test "a server without a vision projector answering images with a 500 is Refused, after one request" do
    stub_request(:post, CHAT_URL).to_return(
      status: 500, headers: JSON_HEADERS,
      body: { error: { code: 500, message: "image input is not supported - hint: if this is unexpected, you may need to provide the mmproj",
                       type: "server_error" } }.to_json
    )

    assert_raises(Ai::Error::Refused) do
      generate(attachments: [ Ai::Attachment.png(PNG, filename: "page-1.png") ], capabilities: %i[structured_output vision],
               endpoint: ai_endpoint(name: "llm", base_url: "https://llm.example.test/v1", max_retries: 2))
    end
    assert_requested :post, CHAT_URL, times: 1
  end

  test "a PDF to a model without documents is refused before anything is sent" do
    stub = stub_request(:post, CHAT_URL)

    assert_raises(Ai::Error::Refused) do
      generate(attachments: [ Ai::Attachment.pdf(PDF) ], capabilities: %i[structured_output vision])
    end
    assert_not_requested stub
  end

  test "a PDF over the preset's inline limit is refused, since uploading it is off" do
    endpoint = ai_endpoint(name: "openai", base_url: "https://api.openai.example.test/v1", preset: :openai, responses_api: true)
    big = Ai::Attachment.pdf("%PDF".b + ("x" * (Ai::Config::Endpoint::PDF_LIMITS.dig(:openai, :bytes) + 1)))

    assert_raises(Ai::Error::Refused) do
      generate(endpoint:, attachments: [ big ], capabilities: %i[structured_output documents])
    end
    assert_equal false, Ai::Transport.for(endpoint).send(:ruby_llm_context).config.auto_upload_large_files
  end

  test "the generate event names each file with its size, never its bytes" do
    stub_json(CHAT_URL, chat_answer)

    events = capture_ai_events do
      generate(attachments: [ Ai::Attachment.png(PNG, filename: "page-1.png") ], capabilities: %i[structured_output vision])
    end

    request = events.sole.payload[:request]
    assert_equal [ { filename: "page-1.png", bytes: PNG.bytesize } ], request[:attachments]
    assert_not_includes events.sole.payload.to_s, Base64.strict_encode64(PNG)
  end

  private
    def generate(attachments:, capabilities:, endpoint: ai_endpoint(name: "llm", base_url: "https://llm.example.test/v1"))
      model = ai_model(endpoint:, capabilities:)
      request = Ai::Transport::Base::Request.new(
        feature: :extract_pdf, model:, instructions: "Read it.", input: "The statement is attached.", schema: SCHEMA,
        schema_name: "statement", json_mode: :strict, attachments:
      )
      Ai::Transport.for(endpoint).generate(request)
    end

    def stub_json(url, body)
      bodies = []
      stub_request(:post, url).to_return(lambda do |request|
        bodies << JSON.parse(request.body)
        { status: 200, headers: JSON_HEADERS, body: body.to_json }
      end)
      bodies
    end

    def chat_answer
      { id: "c1", model: "test-model", choices: [ { index: 0, message: { role: "assistant", content: '{"ok":true}' }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 100, completion_tokens: 5, total_tokens: 105 } }
    end

    def responses_answer
      { id: "resp_1", object: "response", status: "completed", model: "test-model",
        output: [ { type: "message", id: "msg_1", role: "assistant", status: "completed",
                    content: [ { type: "output_text", text: '{"ok":true}', annotations: [] } ] } ],
        usage: { input_tokens: 100, output_tokens: 5, total_tokens: 105 } }
    end

    def anthropic_answer
      { id: "m1", type: "message", role: "assistant", model: "test-model", content: [ { type: "text", text: '{"ok":true}' } ],
        stop_reason: "end_turn", usage: { input_tokens: 100, output_tokens: 5 } }
    end
end
