require "test_helper"

# The `generate` half of the transport contract (section 17): what each JSON mode sends, the
# `auto` chain, the 400 retry without format and effort (#3605), reasoning effort in both API
# forms, tolerant parsing, an answer cut at the output limit, and Anthropic's native structured
# output (2c plan, decision 7). Stubbed through WebMock; the live cassettes are in
# test/models/ai/live/.
class AiTransportGenerateTest < ActiveSupport::TestCase
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  CHAT_URL = "https://llm.example.test/v1/chat/completions".freeze
  RESPONSES_URL = "https://api.openai.example.test/v1/responses".freeze
  MESSAGES_URL = "https://anthropic.example.test/v1/messages".freeze

  SCHEMA = {
    type: "object",
    properties: {
      items: {
        type: "array",
        items: { type: "object", properties: { id: { type: "string" }, name: { type: %w[string null] } },
                 required: %w[id name], additionalProperties: false }
      }
    },
    required: %w[items],
    additionalProperties: false
  }.freeze

  FULL = { items: [ { id: "a", name: "Amazon" }, { id: "b", name: "Netflix" } ] }.freeze
  BLANK = { items: [ { id: "a", name: nil }, { id: "b", name: nil } ] }.freeze

  test "strict sends the schema as a strict response_format" do
    requests = stub_chat(answer(FULL))

    response = generate(json_mode: :strict)

    format = requests.first["response_format"]
    assert_equal "json_schema", format["type"]
    assert_equal true, format.dig("json_schema", "strict")
    assert_equal "items_schema", format.dig("json_schema", "name")
    assert_equal FULL.deep_stringify_keys, response.json
    assert_equal :strict, response.json_mode
  end

  test "auto moves from strict to json_object when most items come back blank, keeping the effort" do
    requests = stub_chat(answer(BLANK), answer(FULL))

    response = generate(json_mode: :auto, reasoning_effort: "low", failed_ratio: method(:blank_share))

    assert_equal %w[json_schema json_object], requests.map { _1.dig("response_format", "type") }
    assert_equal %w[low low], requests.map { _1["reasoning_effort"] }
    assert_equal :json_object, response.json_mode
    assert_equal 2, response.usage.output_tokens / 5
  end

  test "auto moves on when the answer doesn't parse, and stops at none" do
    requests = stub_chat(answer("not json"), answer("still not"), answer("```json\n#{FULL.to_json}\n```"))

    response = generate(json_mode: :auto)

    assert_equal [ "json_schema", "json_object", nil ], requests.map { _1.dig("response_format", "type") }
    assert_equal :none, response.json_mode
  end

  test "blanks are a normal answer without a failed_ratio, so auto keeps strict's answer" do
    requests = stub_chat(answer(BLANK))

    assert_equal :strict, generate(json_mode: :auto).json_mode
    assert_equal 1, requests.size
  end

  test "a 400 about the JSON mode retries once in none mode without the effort" do
    requests = stub_chat(error(400, "'response_format.type' must be 'json_schema' or 'text'"), answer(FULL))

    response = generate(json_mode: :auto, reasoning_effort: "high")

    assert_equal [ "json_schema", nil ], requests.map { _1.dig("response_format", "type") }
    assert_equal [ "high", nil ], requests.map { _1["reasoning_effort"] }
    assert_equal :none, response.json_mode
  end

  test "a 400 about anything else ends the call" do
    requests = stub_chat(error(400, "image input is not supported by this model"))

    assert_raises(Ai::Error::Refused) { generate(json_mode: :auto) }
    assert_equal 1, requests.size
  end

  test "OpenRouter's reasoning-is-mandatory 400 isn't read as a JSON-mode rejection" do
    stub_chat(error(400, "Reasoning is mandatory for this endpoint and cannot be disabled"))

    assert_raises(Ai::Error::Refused) { generate(json_mode: :strict, reasoning_effort: "none") }
  end

  test "none sends no response_format; effort none on a llama.cpp preset turns thinking off its way" do
    plain = stub_chat(answer(FULL))
    generate(json_mode: :none, reasoning_effort: "none")
    assert_nil plain.first["response_format"]
    assert_equal "none", plain.first["reasoning_effort"]

    WebMock.reset!
    llama = stub_chat(answer(FULL))
    generate(json_mode: :none, reasoning_effort: "none", endpoint: { preset: :llama_cpp })
    assert_nil llama.first["reasoning_effort"]
    assert_equal({ "enable_thinking" => false }, llama.first["chat_template_kwargs"])
  end

  test "a think block, fences and prose around the JSON are parsed" do
    stub_chat(answer("<think>the user wants JSON</think>\nHere you go:\n```json\n#{FULL.to_json}\n```\nDone."))

    assert_equal FULL.deep_stringify_keys, generate(json_mode: :none).json
  end

  test "an answer cut at the output limit is OutputCut, so the batch is split" do
    stub_chat(answer('{"items": [{"id": "a", "na', finish_reason: "length"))

    assert_raises(Ai::Error::OutputCut) { generate(json_mode: :strict) }
  end

  test "an answer that never parses is InvalidOutput" do
    stub_chat(answer("no"), answer("nope"))

    assert_raises(Ai::Error::InvalidOutput) { generate(json_mode: :strict) }
  end

  test "the Responses API takes the strict schema and the effort as reasoning.effort" do
    requests = stub_json(RESPONSES_URL, [ 200, responses_answer(FULL) ])
    endpoint = ai_endpoint(name: "openai", preset: :openai, base_url: "https://api.openai.example.test/v1", responses_api: true)

    response = generate(json_mode: :none, reasoning_effort: "low", endpoint_value: endpoint)

    assert_equal "json_schema", requests.first.dig("text", "format", "type")
    assert_equal true, requests.first.dig("text", "format", "strict")
    assert_equal({ "effort" => "low" }, requests.first["reasoning"].slice("effort"))
    assert_equal FULL.deep_stringify_keys, response.json
  end

  test "Anthropic gets the schema as native structured output, with no tool" do
    requests = stub_json(MESSAGES_URL, [ 200, anthropic_answer(FULL) ])
    endpoint = ai_endpoint(name: "anthropic", protocol: :anthropic, base_url: "https://anthropic.example.test")

    response = generate(json_mode: :auto, reasoning_effort: "high", endpoint_value: endpoint, max_output_tokens: 4096)

    body = requests.first
    assert_equal "json_schema", body.dig("output_config", "format", "type")
    assert_nil body["tools"]
    assert_nil body["tool_choice"]
    assert_equal 4096, body["max_tokens"]
    assert_nil body["thinking"]
    assert_equal FULL.deep_stringify_keys, response.json
  end

  test "the generate.ai event carries the route, the summed usage and the JSON mode" do
    stub_chat(answer(BLANK), answer(FULL))

    events = capture_ai_events { generate(json_mode: :auto, failed_ratio: method(:blank_share)) }

    event = events.find { _1.name == "generate.ai" }
    assert_equal "items", event.payload[:feature]
    assert_equal :json_object, event.payload[:json_mode]
    assert_equal 10, event.payload[:usage].output_tokens
    assert_equal FULL.deep_stringify_keys, event.payload[:output]
  end

  private
    def generate(json_mode:, reasoning_effort: nil, failed_ratio: nil, endpoint: {}, endpoint_value: nil, max_output_tokens: nil)
      endpoint_value ||= ai_endpoint(name: "llm", base_url: "https://llm.example.test/v1", **endpoint)
      model = ai_model(endpoint: endpoint_value, max_output_tokens:)
      request = Ai::Transport::Base::Request.new(
        feature: :items, model:, instructions: "Name each item.", input: "a, b", schema: SCHEMA, schema_name: "items_schema",
        reasoning_effort:, json_mode:, failed_ratio:
      )
      Ai::Transport.for(endpoint_value).generate(request)
    end

    def blank_share(json) = json["items"].count { _1["name"].nil? } / json["items"].size.to_f

    # Answers in order (the last one repeats) and records each request's body once.
    def stub_chat(*bodies) = stub_json(CHAT_URL, *bodies)

    def stub_json(url, *bodies)
      requests = []
      queue = bodies.map { |status, body| { status:, headers: JSON_HEADERS, body: body.to_json } }
      stub_request(:post, url).to_return(lambda do |request|
        requests << JSON.parse(request.body)
        queue.size > 1 ? queue.shift : queue.first
      end)
      requests
    end

    def answer(content, finish_reason: "stop")
      content = content.to_json unless content.is_a?(String)
      [ 200, { id: "c1", model: "test-model", choices: [ { index: 0, message: { role: "assistant", content: }, finish_reason: } ],
               usage: { prompt_tokens: 100, completion_tokens: 5, total_tokens: 105 } } ]
    end

    def error(status, message) = [ status, { error: { message:, type: "invalid_request_error" } } ]

    def responses_answer(json)
      { id: "resp_1", object: "response", status: "completed", model: "test-model",
        output: [ { type: "message", id: "msg_1", role: "assistant", status: "completed",
                    content: [ { type: "output_text", text: json.to_json, annotations: [] } ] } ],
        usage: { input_tokens: 100, output_tokens: 5, total_tokens: 105 } }
    end

    def anthropic_answer(json)
      { id: "m1", type: "message", role: "assistant", model: "test-model", content: [ { type: "text", text: json.to_json } ],
        stop_reason: "end_turn", usage: { input_tokens: 100, output_tokens: 5 } }
    end
end
