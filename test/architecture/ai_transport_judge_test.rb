require "test_helper"

# The `judge` half of the transport contract: what the Jev transport sends through
# RubyLLM's `typesafe` provider, its fan-out, error mapping, malformed answers and usage rows.
# Stubbed through WebMock; the live recording is test/models/ai/live/judge_live_test.rb.
class AiTransportJudgeTest < ActiveSupport::TestCase
  URL = "https://api.typesafe.ai/v1/systemone".freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  OPTIONS = { "Coffee Shops" => "Subcategory of Food", "Salary" => nil, "__uncategorized__" => "No listed category is a reasonable fit" }.freeze
  QUESTIONS = { category: { type: :choice, instructions: "Which category fits?", options: OPTIONS } }.freeze
  # OpenRouter's decisions API requires a description for every choice. Keep the TypeSafe case's
  # nil option, but never send it to that gateway.
  OPENROUTER_OPTIONS = { "Coffee Shops" => "Subcategory of Food", "Salary" => "Salary",
                         "__uncategorized__" => "No listed category is a reasonable fit" }.freeze
  OPENROUTER_QUESTIONS = { category: { type: :choice, instructions: "Which category fits?", options: OPENROUTER_OPTIONS } }.freeze

  setup do
    @family = families(:dylan_family)
    Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
  end

  test "OpenRouter questions give every choice a description" do
    assert OPENROUTER_OPTIONS.values.none?(&:nil?)
  end

  test "sends one System One request per state and reads the typed answer" do
    bodies = stub_jev(answer("Coffee Shops", 0.92))

    response = judge({ "txn_1" => { description: "STARBUCKS 1234", amount: 4.5 } })

    body = bodies.first
    assert_equal "jev-latest", body["model"]
    assert_equal({ "description" => "STARBUCKS 1234", "amount" => 4.5 }, body["state"])
    assert_equal({ "type" => "choice", "instructions" => "Which category fits?", "criteria" => OPTIONS }, body.dig("questions", "category"))
    assert_requested(:post, URL, headers: { "Authorization" => "Bearer test-key" })

    choice = response.answers.fetch("txn_1").fetch(:category)
    assert_equal "Coffee Shops", choice.choice
    assert_in_delta 0.92, choice.confidence
    assert_equal 0.92, choice.probabilities["Coffee Shops"]
    assert_equal 120, response.usage.input_tokens
  end

  test "each attempt waits only what's left of the call's budget" do
    stub_jev(answer("Salary", 0.8))
    Ai::CallContext::Call.any_instance.stubs(:remaining).returns(2.5)
    Ai::Transport::Jev.any_instance.expects(:ruby_llm_context).with(timeout: 2.5).returns(RubyLLM.context { _1.typesafe_api_key = "test-key" })

    judge({ "txn_1" => { description: "row" } })
  end

  test "an answer whose confidence isn't a number fails only its own state" do
    stub_request(:post, URL).to_return(lambda do |request|
      bad = JSON.parse(request.body).dig("state", "description") == "bad"
      body = answer("Salary", 0.8).deep_merge(answers: { category: { confidence: (bad ? {} : 0.8) } })
      { status: 200, headers: JSON_HEADERS, body: body.to_json }
    end)

    response = judge({ "good" => { description: "good" }, "bad" => { description: "bad" } })

    assert_equal "Salary", response.answers.fetch("good").fetch(:category).choice
    assert_nil response.answers.fetch("bad")
    assert_equal 240, response.usage.input_tokens, "the rejected answer was still billed"
  end

  test "an OpenRouter decisions 200 with an embedded error body is an outage, not a refusal" do
    decisions_url = "https://openrouter.ai/api/alpha/decisions"
    stub_request(:post, decisions_url).to_return(status: 200, headers: JSON_HEADERS,
                                                   body: { error: { code: 500, message: "upstream is down" } }.to_json)

    assert_raises(Ai::Error::Upstream) { judge({ "txn_1" => { description: "x" } },
                                                questions: OPENROUTER_QUESTIONS, preset: :jev_openrouter, base_url: "https://openrouter.ai/api/v1") }
  end

  test "fans a batch out on at most parallel_requests threads" do
    in_flight = Concurrent::AtomicFixnum.new
    peak = Concurrent::AtomicFixnum.new
    both_in = Concurrent::CountDownLatch.new(2)   # the first two requests wait for each other
    stub_request(:post, URL).to_return(lambda do |_request|
      now = in_flight.increment
      peak.update { [ _1, now ].max }   # update may run its block twice, so the block only compares
      both_in.count_down
      both_in.wait(2)   # bounded, so a serial transport fails the assertion instead of hanging
      in_flight.decrement
      { status: 200, headers: JSON_HEADERS, body: answer("Salary", 0.8).to_json }
    end)

    response = judge((1..6).to_h { [ "txn_#{_1}", { description: "row #{_1}" } ] }, parallel_requests: 2)

    assert_equal 6, response.answers.size
    assert_operator peak.value, :<=, 2
    assert_operator peak.value, :>=, 2, "the requests ran concurrently"
  end

  test "an endpoint can't be built with fewer than one request in flight" do
    error = assert_raises(ArgumentError) { jev_endpoint(parallel_requests: 0) }
    assert_match "parallel_requests must be at least 1", error.message
  end

  test "a failover error stops the fan-out: queued states aren't sent" do
    bodies = stub_jev([ 401, { detail: "invalid key" } ])
    states = (1..4).to_h { [ "txn_#{_1}", { description: "row #{_1}" } ] }

    assert_raises(Ai::Error::Unauthorized) { judge(states, parallel_requests: 1) }
    assert_equal 1, bodies.size
  end

  test "an all-malformed batch is attributed: both billed requests are failed rows under one call" do
    malformed = { model: "jev-latest", answers: { category: { type: "choice", choice: "Not asked" } },
                  usage: { input_tokens: 120, output_tokens: 0 } }
    stub_request(:post, URL).to_return(lambda do |request|
      body = JSON.parse(request.body)
      { status: 200, headers: JSON_HEADERS, body: malformed.to_json }
    end)

    before = @family.llm_usages.where(operation: "categorize").count
    assert_raises(Ai::Error::InvalidOutput) do
      judge({ "txn_1" => { description: "bad one" }, "txn_2" => { description: "bad two" } }, family: @family)
    end

    rows = @family.llm_usages.where(operation: "categorize").order(:created_at).offset(before)
    assert_equal 2, rows.size, "a billed request that can't be read is a failed row, not an invisible one"
    assert rows.all? { _1.status == "failed" }
    assert_equal 1, rows.map(&:call_id).uniq.size
    assert_equal [ 120, 120 ], rows.map(&:prompt_tokens), "the billed tokens stay on the failed row (crmne/ruby_llm#1614)"
    assert rows.none? { _1.metadata["tokens_unknown"] }
  end

  test "every request of the fan-out writes a usage row with the call's id" do
    stub_jev(answer("Salary", 0.9))

    before = @family.llm_usages.where(operation: "categorize").count
    judge({ "txn_1" => { description: "a" }, "txn_2" => { description: "b" }, "txn_3" => { description: "c" } }, family: @family)

    rows = @family.llm_usages.where(operation: "categorize").order(:created_at).offset(before)
    assert_equal 3, rows.size
    assert_equal 1, rows.map(&:call_id).uniq.size
    assert rows.first.call_id.present?
    assert_equal [ "jev" ], rows.map(&:provider).uniq
    assert_equal [ 120 ], rows.map(&:prompt_tokens).uniq
  end

  private
    def jev_endpoint(**attributes)
      ai_endpoint(name: "jev", protocol: :jev, preset: :jev, base_url: "https://api.typesafe.ai", **attributes)
    end

    def judge(states, questions: QUESTIONS, family: nil, **endpoint)
      endpoint = jev_endpoint(**endpoint)
      model = ai_model(name: "jev-latest", endpoint:, capabilities: %i[judge calibrated_confidence])
      request = Ai::Transport::Base::JudgeRequest.new(feature: :categorize, family:, model:, states:, questions:)
      Ai::Transport.for(endpoint).judge(request)
    end

    def answer(choice, confidence)
      probabilities = OPTIONS.keys.index_with { _1 == choice ? confidence : ((1 - confidence) / (OPTIONS.size - 1)).round(4) }
      { model: "jev-latest", answers: { category: { type: "choice", choice:, probabilities:, confidence: } },
        usage: { input_tokens: 120, output_tokens: 0 } }
    end

    # Answers in order (the last one repeats) and records each request's body once.
    def stub_jev(*bodies)
      requests = []
      queue = bodies.map { |body| body.is_a?(Array) ? body : [ 200, body ] }.map { |status, body| { status:, headers: JSON_HEADERS, body: body.to_json } }
      WebMock.reset!
      stub_request(:post, URL).to_return(lambda do |request|
        requests << JSON.parse(request.body)
        queue.size > 1 ? queue.shift : queue.first
      end)
      requests
    end
end
