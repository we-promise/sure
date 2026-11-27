require "test_helper"

# What the gate needs from the transports (PR 4, step 4): a local generation streams, so the
# server stops when an interrupt closes the connection; an interrupted request is sent again to
# the same endpoint and is neither a try, a down mark nor a failed request on the usage page; and
# streamed chunks never reach the log.
class AiTransportLocalStreamTest < ActiveSupport::TestCase
  ai_capsule!
  LOCAL_URL = "http://gpu.local:8080/v1/chat/completions".freeze
  CLOUD_URL = "https://llm.example.test/v1/chat/completions".freeze
  SCHEMA = {
    type: "object", properties: { name: { type: "string" } }, required: %w[name], additionalProperties: false
  }.freeze

  setup do
    @family = families(:dylan_family)
    @local = ai_endpoint(name: "gpu", base_url: "http://gpu.local:8080/v1", location: :local)
  end

  test "a local generation streams and returns the whole answer with its usage" do
    requests = stub_stream(LOCAL_URL, { name: "Amazon" })

    response = generate(@local)

    assert_equal true, requests.sole["stream"]
    assert_equal({ "include_usage" => true }, requests.sole["stream_options"])
    assert_equal({ "name" => "Amazon" }, response.json)
    assert_equal [ 12, 5 ], [ response.usage.input_tokens, response.usage.output_tokens ]
  end

  test "a cloud generation doesn't stream" do
    stub_request(:post, CLOUD_URL).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "c1", model: "test-model", choices: [ { index: 0, message: { role: "assistant", content: { name: "Amazon" }.to_json }, finish_reason: "stop" } ],
              usage: { prompt_tokens: 12, completion_tokens: 5, total_tokens: 17 } }.to_json
    )

    generate(ai_endpoint(name: "cloud"))

    assert_requested(:post, CLOUD_URL) { JSON.parse(_1.body)["stream"] == false }
  end

  test "an interrupted request is sent again to the same endpoint; its usage row is cancelled, with tokens and cost unknown" do
    requests = []
    stub_request(:post, LOCAL_URL)
      .to_raise(Ai::Gate::Interrupted.new("an interactive request needed the model host"))
      .then.to_return(lambda do |request|
        requests << request
        { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse({ name: "Amazon" }) }
      end)
    rows = LlmUsage.where(family: @family)

    response = assert_difference -> { rows.count }, 2 do
      generate(@local, family: @family, max_retries: 0)
    end

    assert_equal({ "name" => "Amazon" }, response.json)
    assert_requested :post, LOCAL_URL, times: 2
    cancelled, succeeded = rows.order(:created_at).last(2)
    assert_equal %w[cancelled succeeded], [ cancelled.status, succeeded.status ]
    assert_equal true, cancelled.metadata["tokens_unknown"]
    assert_nil cancelled.estimated_cost
    assert_nil cancelled.metadata["error"], "an interrupted request isn't a failure"
    assert_equal 0, rows.where(status: "failed").count
    assert_equal cancelled.call_id, succeeded.call_id
  end

  test "an interrupted request isn't a try, and the time it ran isn't spent from the budget" do
    interrupted_after = ->(seconds) { ->(_request) { sleep(seconds).then { raise Ai::Gate::Interrupted, "interrupted" } } }
    stub_request(:post, LOCAL_URL)
      .to_return(interrupted_after.(0.6)).then.to_return(interrupted_after.(0.6))
      .then.to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse({ name: "Amazon" }))

    response = generate(@local.with(timeout_seconds: 1), max_retries: 0)

    assert_equal({ "name" => "Amazon" }, response.json, "1.2 s of interrupted requests on a 1 s budget, with no retries")
    assert_requested :post, LOCAL_URL, times: 3
  end

  test "a busy local host isn't a down mark, and the next route isn't tried" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    occupied = Queue.new
    release = Queue.new
    holder = Thread.new { Ai::Sequencer.gate_for(@local).hold(:interactive) { occupied << true; release.pop } }
    occupied.pop(timeout: 2)
    cloud = ai_endpoint(name: "cloud")
    capabilities = %i[structured_output]
    models = [ ai_model(endpoint: @local, name: "qwen3-8b", capabilities:), ai_model(endpoint: cloud, name: "gpt-4.1-mini", capabilities:) ]
    stub_request(:post, CLOUD_URL).to_raise("the next route shouldn't be tried")

    Ai::Config.with(AiTestHelper.build_ai_config(models, { detect_merchants: %w[gpu/qwen3-8b cloud/gpt-4.1-mini] })) do
      generation = AiTestGeneration.new(transactions: [ { id: "t1", description: "AMZN", merchant: nil } ], family: @family)

      assert_raises(Ai::Error::Busy) { Ai::Sequencer.with_lane(:background) { generation.call } }
      route = Ai::Router.new(family: @family).resolve(:detect_merchants).routes.first
      assert_equal :up, Ai::DownMarks.state(route)
    end
    assert_not_requested :post, LOCAL_URL
  ensure
    release&.push(true)
    holder&.join(2)
  end

  test "streamed chunks never reach the log, even with RUBYLLM_STREAM_DEBUG" do
    stub_stream(LOCAL_URL, { name: "Secret Merchant" })
    log = StringIO.new
    logger = RubyLLM.config.logger
    RubyLLM.config.logger = Logger.new(log, level: :debug)

    ClimateControl.modify("RUBYLLM_STREAM_DEBUG" => "true") { generate(@local) }

    assert_not_includes log.string, "Secret Merchant"
    assert_not_includes log.string, "Received chunk"
  ensure
    RubyLLM.config.logger = logger
  end

  private
    def generate(endpoint, family: nil, max_retries: 0)
      endpoint = endpoint.with(max_retries:)
      model = ai_model(endpoint:, name: "test-model")
      request = Ai::Transport::Base::Request.new(feature: :items, family:, model:, instructions: "Name it.", input: "AMZN",
                                                 schema: SCHEMA, schema_name: "items_schema", json_mode: :strict)
      Ai::Transport.for(endpoint).generate(request)
    end

    # Server-sent events as llama.cpp streams them: the answer, the finish, then usage.
    def sse(json)
      [
        { choices: [ { index: 0, delta: { role: "assistant", content: json.to_json } } ] },
        { choices: [ { index: 0, delta: {}, finish_reason: "stop" } ] },
        { choices: [], usage: { prompt_tokens: 12, completion_tokens: 5, total_tokens: 17 } }
      ].map { "data: #{_1.to_json}\n\n" }.join + "data: [DONE]\n\n"
    end

    def stub_stream(url, json)
      requests = []
      stub_request(:post, url).to_return(lambda do |request|
        requests << JSON.parse(request.body)
        { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse(json) }
      end)
      requests
    end
end
