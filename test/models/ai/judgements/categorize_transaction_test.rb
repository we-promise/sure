require "test_helper"

# Categorization on a decision model: the question Jev is asked, what comes back, and the
# generation's loop switching class on a `judge` route.
class Ai::Judgements::CategorizeTransactionTest < ActiveSupport::TestCase
  TRANSACTIONS = [
    { id: "txn_1", amount: 4.5, classification: "expense", description: "STARBUCKS 1234", merchant: nil },
    { id: "txn_2", amount: 2500, classification: "income", description: "ACME PAYROLL", merchant: "Acme" }
  ].freeze
  CATEGORIES = [
    { id: "cat_food", name: "Food", is_subcategory: false, parent_id: nil },
    { id: "cat_coffee", name: "Coffee Shops", is_subcategory: true, parent_id: "cat_food" },
    { id: "cat_salary", name: "Salary", is_subcategory: false, parent_id: nil }
  ].freeze

  setup do
    @family = families(:dylan_family)
    use_ai_routes(categorize: %w[jev/jev-latest])
  end

  def generation(transactions = TRANSACTIONS, categories = CATEGORIES)
    Ai::Generations::CategorizeTransactions.new(transactions:, categories:, family: @family)
  end

  test "asks one Choice question over the family's categories, with hierarchy hints and an opt-out" do
    requests = stub_ai(:categorize) { |request| request.states.keys.index_with { { category: "Salary" } } }

    generation.call

    request = requests.first
    assert_instance_of Ai::Transport::Base::JudgeRequest, request
    question = request.questions.fetch(:category)
    assert_equal :choice, question[:type]
    assert_equal Ai::Judgements::CategorizeTransaction::INSTRUCTIONS, question[:instructions]
    assert_equal({ "Food" => nil, "Coffee Shops" => "Subcategory of Food", "Salary" => nil,
                   "__uncategorized__" => "No listed category is a reasonable fit" }, question[:options])
  end

  test "each state holds the transaction's own fields, without its id" do
    requests = stub_ai(:categorize) { |request| request.states.keys.index_with { { category: "Salary" } } }

    generation.call

    assert_equal({ description: "ACME PAYROLL", amount: 2500, classification: "income", merchant: "Acme" },
                 requests.first.states.fetch("txn_2"))
    assert_equal({ description: "STARBUCKS 1234", amount: 4.5, classification: "expense" }, requests.first.states.fetch("txn_1"))
  end

  test "a decimal amount is sent as a number" do
    requests = stub_ai(:categorize) { |request| request.states.keys.index_with { { category: "Salary" } } }

    generation([ TRANSACTIONS.first.merge(amount: BigDecimal("4.50")) ]).call

    assert_equal 4.5, requests.first.states.fetch("txn_1")[:amount]
    assert_kind_of Float, requests.first.states.fetch("txn_1")[:amount]
  end

  test "answers in the generation's shape, the opt-out as no category, with confidence and probabilities" do
    stub_ai(:categorize) { { "txn_1" => { category: [ "Coffee Shops", 0.93 ] }, "txn_2" => { category: [ "__uncategorized__", 0.4 ] } } }

    result = generation.call

    assert_equal "jev", result.route.endpoint.name
    first, second = result.value[:categorizations]
    assert_equal({ transaction_id: "txn_1", category_name: "Coffee Shops", confidence: 0.93, probabilities: { "Coffee Shops" => 0.93 } }, first)
    assert_nil second[:category_name]
    assert_equal 0.4, second[:confidence]
  end

  # The family's threshold is compared with this in 0..1; an out-of-range value would clear any
  # threshold, and an answer would be applied and locked.
  test "a confidence outside 0..1 is clamped" do
    stub_ai(:categorize) { { "txn_1" => { category: [ "Salary", 1.5 ] }, "txn_2" => { category: [ "Salary", -0.2 ] } } }

    assert_equal [ 1.0, 0.0 ], generation.call.value[:categorizations].map { _1[:confidence] }
  end

  test "a malformed answer leaves its transaction out" do
    stub_ai(:categorize) { { "txn_2" => { category: "Salary" } } }

    assert_equal [ "txn_2" ], generation.call.value[:categorizations].map { _1[:transaction_id] }
  end

  test "more categories than one Choice can hold is refused" do
    categories = Array.new(255) { |i| { id: "c#{i}", name: "Category #{i}", is_subcategory: false, parent_id: nil } }
    stub_ai(:categorize) { flunk "no request should be sent" }

    assert_raises(Ai::Error::Refused) { generation(TRANSACTIONS, categories).call! }
  end

  test "batches a judge model by its batch size, with no prompt to cost" do
    use_ai_routes(categorize: %w[jev/jev-latest])

    requests = stub_ai(:categorize) { |request| request.states.keys.index_with { { category: "Salary" } } }
    transactions = Array.new(30) { |i| { id: "t#{i}", description: "ROW #{i}" } }

    result = generation(transactions).call

    assert_equal [ 25, 5 ], requests.map { _1.states.size }
    assert_equal 30, result.value[:categorizations].size
  end

  test "failover from a judge model to an LLM switches class, in the same shape" do
    use_ai_routes(categorize: %w[jev/jev-latest openai/gpt-4.1-mini])

    requests = stub_ai(:categorize) do |request|
      raise Ai::Error::Upstream, "jev is down" if request.is_a?(Ai::Transport::Base::JudgeRequest)

      { categorizations: [ { transaction_id: "txn_1", category_name: "Coffee Shops" }, { transaction_id: "txn_2", category_name: "Salary" } ] }
    end

    result = generation.call

    assert_equal [ Ai::Transport::Base::JudgeRequest, Ai::Transport::Base::Request ], requests.map(&:class)
    assert_equal "openai", result.route.endpoint.name
    assert_equal [ "jev" ], result.failed_over_from.map { _1.endpoint.name }
    assert_equal %w[Coffee\ Shops Salary], result.value[:categorizations].map { _1[:category_name] }
  end

  test "a feature without a judgement can't be served by a judge model" do
    use_ai_routes(detect_merchants: %w[jev/jev-latest])

    result = AiTestGeneration.new(transactions: [ { id: "t1", description: "SHOP" } ], family: @family).call

    assert_equal :capability_missing, result.availability.reason
  end
end
