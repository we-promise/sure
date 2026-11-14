require "test_helper"

# The `judge` half of the transport contract: what the Jev transport sends through
# RubyLLM's `typesafe` provider, its fan-out, error mapping, malformed answers and usage rows.
# Stubbed through WebMock; the live recording is test/models/ai/live/judge_live_test.rb.
class AiTransportJudgeTest < ActiveSupport::TestCase
  URL = "https://api.typesafe.ai/v1/systemone".freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze
  OPTIONS = { "Coffee Shops" => "Subcategory of Food", "Salary" => nil, "__uncategorized__" => "No listed category is a reasonable fit" }.freeze
  QUESTIONS = { category: { type: :choice, instructions: "Which category fits?", options: OPTIONS } }.freeze

  setup do
    @family = families(:dylan_family)
    Ai::Transport::Base.any_instance.stubs(:retry_delay).returns(0)
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

  test "an OpenRouter decisions preset posts the OpenRouter dialect to the decisions URL" do
    decisions_url = "https://openrouter.ai/api/alpha/decisions"
    stub_request(:post, decisions_url).to_return(status: 200, headers: JSON_HEADERS, body: answer("Salary", 0.8).to_json)

    response = judge({ "txn_1" => { description: "ACME CORP", amount: 10.0 } },
                     preset: :jev_openrouter, base_url: "https://openrouter.ai/api/v1")

    assert_equal "Salary", response.answers.fetch("txn_1").fetch(:category).choice
    assert_requested(:post, decisions_url,
                     headers: { "Authorization" => "Bearer test-key",
                                "X-OpenRouter-Title" => "Sure",
                                "HTTP-Referer" => "https://sure.am" })
  end

  test "an OpenRouter decisions 401, 402 and a retried 429 map the same as TypeSafe" do
    decisions_url = "https://openrouter.ai/api/alpha/decisions"
    { 401 => Ai::Error::Unauthorized, 402 => Ai::Error::NoCredit }.each do |status, expected|
      stub_request(:post, decisions_url).to_return(status:, headers: JSON_HEADERS,
                                                     body: { error: { code: status, message: "err" } }.to_json)

      assert_raises(expected) { judge({ "txn_1" => { description: "x" } },
                                       preset: :jev_openrouter, base_url: "https://openrouter.ai/api/v1") }
      WebMock.reset!
    end

    stub_request(:post, decisions_url).to_return(
      { status: 429, headers: JSON_HEADERS, body: { error: { code: 429, message: "slow down" } }.to_json },
      { status: 200, headers: JSON_HEADERS, body: answer("Salary", 0.6).to_json }
    )

    assert_equal "Salary", judge({ "txn_1" => { description: "x" } }, max_retries: 1,
                                 preset: :jev_openrouter, base_url: "https://openrouter.ai/api/v1")
                          .answers["txn_1"][:category].choice
  end

  test "an OpenRouter decisions 200 with an embedded error body is an outage, not a refusal" do
    decisions_url = "https://openrouter.ai/api/alpha/decisions"
    stub_request(:post, decisions_url).to_return(status: 200, headers: JSON_HEADERS,
                                                   body: { error: { code: 500, message: "upstream is down" } }.to_json)

    assert_raises(Ai::Error::Upstream) { judge({ "txn_1" => { description: "x" } },
                                                preset: :jev_openrouter, base_url: "https://openrouter.ai/api/v1") }
  end

  test "an OpenRouter decisions 503 after the retries fails the batch for failover" do
    decisions_url = "https://openrouter.ai/api/alpha/decisions"
    stub_request(:post, decisions_url).to_return(status: 503, headers: JSON_HEADERS,
                                                   body: { error: { code: 503, message: "down" } }.to_json)

    assert_raises(Ai::Error::Upstream) { judge({ "txn_1" => { description: "x" } }, max_retries: 1,
                                                preset: :jev_openrouter, base_url: "https://openrouter.ai/api/v1") }
  end

  test "fans a batch out on at most parallel_requests threads" do
    in_flight = Concurrent::AtomicFixnum.new
    peak = Concurrent::AtomicFixnum.new
    stub_request(:post, URL).to_return(lambda do |_request|
      peak.update { [ _1, in_flight.increment ].max }
      sleep 0.05
      in_flight.decrement
      { status: 200, headers: JSON_HEADERS, body: answer("Salary", 0.8).to_json }
    end)

    response = judge((1..6).to_h { [ "txn_#{_1}", { description: "row #{_1}" } ] }, parallel_requests: 2)

    assert_equal 6, response.answers.size
    assert_operator peak.value, :<=, 2
    assert_operator peak.value, :>=, 2, "the requests ran concurrently"
  end

  test "a self-hosted server sends one request at a time by default" do
    assert_equal 1, Ai::Transport.for(jev_endpoint(location: :local, base_url: "http://jev:8080")).parallel_requests
    assert_equal 8, Ai::Transport.for(jev_endpoint).parallel_requests
  end

  test "an endpoint can't be built with fewer than one request in flight" do
    error = assert_raises(ArgumentError) { jev_endpoint(parallel_requests: 0) }
    assert_match "parallel_requests must be at least 1", error.message
  end

  test "an http base on a local endpoint is used as given" do
    stub_request(:post, "http://jev:8080/v1/systemone").to_return(status: 200, headers: JSON_HEADERS, body: answer("Salary", 0.7).to_json)

    response = judge({ "txn_1" => { description: "ACME PAYROLL" } }, location: :local, base_url: "http://jev:8080")

    assert_equal "Salary", response.answers["txn_1"][:category].choice
  end

  test "maps 401 and 402, and retries a 429" do
    stub_jev([ 401, { detail: "invalid key" } ])
    assert_raises(Ai::Error::Unauthorized) { judge({ "txn_1" => { description: "x" } }) }

    stub_jev([ 402, { detail: "balance exhausted" } ])
    assert_raises(Ai::Error::NoCredit) { judge({ "txn_1" => { description: "x" } }) }

    bodies = stub_jev([ 429, { detail: "slow down" } ], answer("Salary", 0.6))
    assert_equal "Salary", judge({ "txn_1" => { description: "x" } }, max_retries: 1).answers["txn_1"][:category].choice
    assert_equal 2, bodies.size
  end

  test "a 5xx after the retries fails the batch for failover" do
    stub_jev([ 503, { detail: "overloaded" } ])

    assert_raises(Ai::Error::Upstream) { judge({ "txn_1" => { description: "x" }, "txn_2" => { description: "y" } }, max_retries: 1) }
  end

  test "a malformed answer fails only its state" do
    stub_request(:post, URL).to_return(lambda do |request|
      body = JSON.parse(request.body)
      answer = body.dig("state", "description") == "bad" ? { answers: { category: { type: "choice", choice: "Salary" } } } : answer("Salary", 0.9)
      { status: 200, headers: JSON_HEADERS, body: answer.to_json }
    end)

    response = judge({ "txn_1" => { description: "bad" }, "txn_2" => { description: "good" } })

    assert_nil response.answers["txn_1"], "a choice with no confidence is malformed"
    assert_equal "Salary", response.answers["txn_2"][:category].choice
  end

  test "an all-malformed batch is attributed: both billed requests are failed rows under one call" do
    malformed = { model: "jev-latest", answers: { category: { type: "choice", choice: "Not asked" } } }
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
  end

  test "an option that wasn't asked for is malformed, and all malformed is InvalidOutput" do
    stub_jev(answer("Groceries", 0.9))

    assert_raises(Ai::Error::InvalidOutput) { judge({ "txn_1" => { description: "x" } }) }
  end

  test "refuses questions built from a Proc" do
    questions = { category: { type: :choice, instructions: "Which?", options: -> { OPTIONS } } }

    assert_raises(ArgumentError) { judge({ "txn_1" => { description: "x" } }, questions:) }
  end

  test "one judge.ai event per batch, without the states" do
    stub_jev(answer("Salary", 0.9))
    events = []
    subscription = ActiveSupport::Notifications.subscribe("judge.ai") { events << _1.payload }

    judge({ "txn_1" => { description: "ACME PAYROLL" }, "txn_2" => { description: "ACME PAYROLL" } })

    assert_equal 1, events.size
    assert_equal 2, events.first.dig(:request, :items)
    assert_not_includes events.first[:request].to_s, "ACME"
    assert_equal "Salary", events.first.dig(:output, "txn_1", :category, :choice)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
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

  test "Jev doesn't generate" do
    request = Ai::Transport::Base::Request.new(feature: :categorize, model: ai_model(endpoint: jev_endpoint), instructions: "",
                                               input: "", schema: {}, schema_name: "x")

    assert_raises(NotImplementedError) { Ai::Transport.for(jev_endpoint).generate(request) }
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
