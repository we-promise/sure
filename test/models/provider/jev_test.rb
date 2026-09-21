require "test_helper"

class Provider::JevTest < ActiveSupport::TestCase
  ENDPOINT = "https://api.typesafe.ai/v1/systemone".freeze

  setup do
    @provider = Provider::Jev.new("test_api_key")
  end

  def choice_body(choice:, confidence: 0.9, probabilities: nil, key: "category")
    {
      "model" => "typesafe/jev-1.13-20260917",
      "answers" => {
        key => {
          "type" => "choice",
          "choice" => choice,
          "probabilities" => probabilities || { choice => confidence },
          "confidence" => confidence
        }
      },
      "usage" => { "input_tokens" => 400, "output_tokens" => 60, "cost" => 0.00002 }
    }.to_json
  end

  def categories
    [
      { id: "1", name: "Groceries", parent_id: nil },
      { id: "2", name: "Restaurants & Bars", parent_id: nil },
      { id: "3", name: "Coffee", parent_id: "2" }
    ]
  end

  def transaction(id: "t1", description: "SQ *BLUE BOTTLE COFFEE", merchant: nil)
    { id: id, description: description, amount: 6.75, classification: "expense", merchant: merchant }
  end

  test "categorizes a transaction and carries the reported confidence" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: choice_body(choice: "Coffee", confidence: 0.97),
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.auto_categorize(transactions: [ transaction ], user_categories: categories)

    assert response.success?
    decision = response.data.sole
    assert_equal "t1", decision.transaction_id
    assert_equal "Coffee", decision.category_name
    assert_in_delta 0.97, decision.confidence, 0.001
  end

  test "attributes per-request usage to each categorized transaction" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: choice_body(choice: "Groceries"),
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.auto_categorize(transactions: [ transaction ], user_categories: categories)

    # One request per transaction means cost is attributable per sample, which
    # is what lets the eval report a real cost-per-sample figure.
    usage = response.data.sole.usage
    assert_equal 0.00002, usage["cost"]
    assert_equal 400, usage["input_tokens"]
    assert_equal 60, usage["output_tokens"]
  end

  test "maps the opt-out sentinel back to a nil category" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: choice_body(choice: Provider::Jev::UNCATEGORIZED, confidence: 0.71),
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.auto_categorize(
      transactions: [ transaction(description: "ACH DEBIT 4471920 REF#88213") ],
      user_categories: categories
    )

    assert response.success?
    assert_nil response.data.sole.category_name
  end

  test "offers every category plus an explicit opt-out as choice criteria" do
    stub = stub_request(:post, ENDPOINT)
      .with do |request|
        criteria = JSON.parse(request.body).dig("questions", "category", "criteria")
        assert_equal %w[Groceries Restaurants\ &\ Bars Coffee] + [ Provider::Jev::UNCATEGORIZED ], criteria.keys
        # Categories have no description column, so the hint comes from the hierarchy.
        assert_equal "Subcategory of Restaurants & Bars", criteria["Coffee"]
        assert_nil criteria["Groceries"]
        true
      end
      .to_return(status: 200, body: choice_body(choice: "Coffee"), headers: { "Content-Type" => "application/json" })

    @provider.auto_categorize(transactions: [ transaction ], user_categories: categories)

    assert_requested stub
  end

  test "sends one request per transaction" do
    stub = stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: choice_body(choice: "Groceries"),
      headers: { "Content-Type" => "application/json" }
    )

    transactions = 3.times.map { |i| transaction(id: "t#{i}") }
    response = @provider.auto_categorize(transactions: transactions, user_categories: categories)

    assert response.success?
    assert_equal 3, response.data.size
    assert_requested stub, times: 3
  end

  test "fails when no categories are available" do
    response = @provider.auto_categorize(transactions: [ transaction ], user_categories: [])

    assert_not response.success?
    assert_match(/No categories available/, response.error.message)
  end

  test "parses every answer type from a single multi-question call" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: {
        "model" => "typesafe/jev-1.13-20260917",
        "answers" => {
          "is_recurring" => { "type" => "noul", "noul" => 0.91 },
          "bill_type" => { "type" => "choice", "choice" => "subscription",
                           "probabilities" => { "subscription" => 1.0, "bill" => 0.0 }, "confidence" => 1.0 },
          "clarity" => { "type" => "score", "score" => 1.92,
                         "legend" => { "0" => "Opaque", "1" => "Partial", "2" => "Clear" },
                         "probabilities" => { "0" => 0.01, "1" => 0.07, "2" => 0.92 }, "confidence" => 0.87 }
        },
        "usage" => { "input_tokens" => 625, "output_tokens" => 162, "cost" => 0.00002625 }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.decide(
      state: { description: "NETFLIX.COM" },
      questions: {
        is_recurring: { type: "noul", instructions: "Recurring?", criteria: { true: "yes", false: "no" } },
        bill_type: { type: "choice", instructions: "Kind?", criteria: { subscription: "a", bill: "b" } },
        clarity: { type: "score", instructions: "Clear?", criteria: [ "Opaque", "Partial", "Clear" ] }
      }
    )

    assert response.success?
    set = response.data

    assert_in_delta 0.91, set.value_of(:is_recurring), 0.001
    assert_equal "subscription", set.value_of(:bill_type)
    assert_in_delta 1.92, set.value_of(:clarity), 0.001
    assert_equal({ "input_tokens" => 625, "output_tokens" => 162, "total_tokens" => 787, "cost" => 0.00002625 }, set.usage)
  end

  test "treats a choice with no reported confidence as maximally unconfident" do
    # A malformed answer must read as 0 rather than nil: nil would look like a
    # provider that does not report confidence at all, and sail through a
    # downstream threshold instead of being withheld.
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: { "answers" => { "category" => { "type" => "choice", "choice" => "Coffee" } } }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.auto_categorize(transactions: [ transaction ], user_categories: categories)

    assert response.success?
    assert_equal 0.0, response.data.sole.confidence
  end

  test "does not apply noul arithmetic to a score missing its confidence" do
    # (value - 0.5).abs * 2 is only meaningful for a noul. A score of 1.92 would
    # yield 2.84 — a confidence outside 0..1.
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: { "answers" => { "q" => { "type" => "score", "score" => 1.92 } } }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.decide(
      state: "x",
      questions: { q: { type: "score", instructions: "?", criteria: [ "a", "b", "c" ] } }
    )

    assert_equal 0.0, response.data[:q].confidence
  end

  test "derives confidence for noul answers from distance off the midpoint" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: { "answers" => { "q" => { "type" => "noul", "noul" => 0.5 } } }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.decide(
      state: "x",
      questions: { q: { type: "noul", instructions: "?", criteria: { true: "a", false: "b" } } }
    )

    # 0.5 is maximal uncertainty for a noul, so it maps to zero confidence.
    assert_in_delta 0.0, response.data[:q].confidence, 0.001
  end

  test "rejects an unknown question type before making a request" do
    response = @provider.decide(state: "x", questions: { q: { type: "bogus", instructions: "?", criteria: {} } })

    assert_not response.success?
    assert_match(/unknown type/, response.error.message)
    assert_not_requested :post, ENDPOINT
  end

  test "rejects a score rubric outside the documented level range" do
    response = @provider.decide(state: "x", questions: { q: { type: "score", instructions: "?", criteria: [ "only one" ] } })

    assert_not response.success?
    assert_match(/rubric levels/, response.error.message)
    assert_not_requested :post, ENDPOINT
  end

  test "rejects more categories than one choice question can hold" do
    too_many = (Provider::Jev::MAX_CHOICE_OPTIONS + 1).times.map { |i| { id: i.to_s, name: "Category #{i}", parent_id: nil } }

    response = @provider.auto_categorize(transactions: [ transaction ], user_categories: too_many)

    assert_not response.success?
    assert_match(/Too many categories/, response.error.message)
  end

  test "retries a throttled request" do
    # faraday-retry skips POST unless it is opted in explicitly, so without the
    # methods: [:post] option this backoff never runs and a 429 fails outright.
    stub = stub_request(:post, ENDPOINT)
      .to_return(status: 429, body: "")
      .then.to_return(status: 200, body: choice_body(choice: "Groceries"), headers: { "Content-Type" => "application/json" })

    response = @provider.auto_categorize(transactions: [ transaction ], user_categories: categories)

    assert response.success?
    assert_equal "Groceries", response.data.sole.category_name
    assert_requested stub, times: 2
  end

  test "surfaces a failed request from inside the parallel fan-out" do
    # The fan-out collects futures with value!, so a worker's exception has to
    # propagate rather than leaving a nil in the results array.
    stub_request(:post, ENDPOINT).to_return(status: 500, body: "upstream exploded")

    response = @provider.auto_categorize(
      transactions: [ transaction(id: "t1"), transaction(id: "t2") ],
      user_categories: categories
    )

    assert_not response.success?
    assert_kind_of Provider::Jev::Error, response.error
  end

  test "surfaces a malformed response as a provider error" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200,
      body: { "model" => "jev" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    response = @provider.decide(
      state: "x",
      questions: { q: { type: "choice", instructions: "?", criteria: { a: "a", b: "b" } } }
    )

    assert_not response.success?
    assert_match(/missing 'answers'/, response.error.message)
  end

  test "authenticates with a bearer token" do
    stub = stub_request(:post, ENDPOINT)
      .with(headers: { "Authorization" => "Bearer test_api_key" })
      .to_return(status: 200, body: choice_body(choice: "Groceries"), headers: { "Content-Type" => "application/json" })

    @provider.auto_categorize(transactions: [ transaction ], user_categories: categories)

    assert_requested stub
  end

  test "does not implement pdf processing" do
    # Jev cannot see a file. Extraction stays with a provider that can.
    assert_not @provider.respond_to?(:process_pdf)
  end

  test "requires an explicit Jev key rather than borrowing an OpenRouter one" do
    ENV.stubs(:[]).returns(nil)
    ENV.stubs(:[]).with("JEV_API_KEY").returns(nil)
    ENV.stubs(:[]).with("OPENROUTER_API_KEY").returns("sk-or-unrelated")
    Setting.stubs(:jev_api_key).returns(nil)

    # A self-hoster using OpenRouter for something else must not find Jev
    # silently switched on.
    assert_nil Provider::Jev.api_key
    assert_not Provider::Jev.configured?
  end

  test "uses the Jev key when one is explicitly set" do
    # Pairs with the test above: proves that assertion fails for the right
    # reason (the fallback is gone) rather than because nothing resolves.
    ENV.stubs(:[]).returns(nil)
    ENV.stubs(:[]).with("JEV_API_KEY").returns("jev_key")

    assert_equal "jev_key", Provider::Jev.api_key
    assert Provider::Jev.configured?
  end

  test "goes straight to the vendor by default" do
    # Routing a family's transaction descriptions through a gateway should be an
    # explicit choice, not inherited from a default.
    assert_equal "https://api.typesafe.ai/v1/systemone", Provider::Jev::DEFAULT_ENDPOINT
    assert_equal "jev-latest", Provider::Jev::DEFAULT_MODEL
    assert_not @provider.proxied?
    assert_equal "Jev", @provider.provider_name
  end

  test "reports the host the current configuration will actually send to" do
    # The settings disclosure reads these: naming TypeSafe while a gateway is in
    # front of it would understate who sees the transaction descriptions.
    assert_equal "api.typesafe.ai", Provider::Jev.effective_host
    assert_not Provider::Jev.effective_proxied?

    Setting.jev_endpoint = "https://openrouter.ai/api/alpha/decisions"

    assert_equal "openrouter.ai", Provider::Jev.effective_host
    assert Provider::Jev.effective_proxied?
  ensure
    Setting.jev_endpoint = nil
  end

  test "reaches Jev through a gateway when pointed at one" do
    openrouter = "https://openrouter.ai/api/alpha/decisions"
    provider = Provider::Jev.new("test_api_key", endpoint: openrouter, model: "~typesafe/jev-latest")

    stub = stub_request(:post, openrouter)
      .with { |request| JSON.parse(request.body)["model"] == "~typesafe/jev-latest" }
      .to_return(status: 200, body: choice_body(choice: "Groceries"), headers: { "Content-Type" => "application/json" })

    provider.auto_categorize(transactions: [ transaction ], user_categories: categories)

    assert_requested stub
    # The disclosure has to name this host: descriptions transit it too.
    assert provider.proxied?
    assert_equal "openrouter.ai", provider.endpoint_host
    assert_equal "Jev via openrouter.ai", provider.provider_name
  end
end
