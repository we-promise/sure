require "test_helper"

# A batch that overflows is halved on the same route until every item is answered;
# only an item that can't fit on its own escalates to the next route.
class AiBatchSplitTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
  end

  def transactions(count) = Array.new(count) { |i| { id: "t#{i}", description: "SHOP #{i}", merchant: nil } }

  def ids_in(request) = request.input.scan(/ID: (\S+),/).flatten

  test "a transaction that breaks the answer on every route is found by halving, skipped and logged" do
    requests = stub_ai do |request|
      raise Ai::Error::InvalidOutput, "not JSON" if ids_in(request).include?("t2")

      AiTestGeneration.answer(request)
    end

    result = AiTestGeneration.new(transactions: transactions(4), family: @family).call

    assert result.success?
    assert_equal %w[t0 t1 t3], result.value[:merchants].map { _1[:transaction_id] }.sort
    assert_equal %w[t2], DebugLogEntry.find_by!(category: "ai_generation", family: @family).metadata["item_ids"]
    # Both routes first, then halves and quarters on the first route.
    assert_equal [ %w[t0 t1 t2 t3], %w[t0 t1 t2 t3], %w[t0 t1], %w[t2 t3], %w[t2], %w[t3] ], requests.map { ids_in(_1) }
  end

  test "a model that can't answer anything stops after two halvings and fails the batch" do
    requests = stub_ai(raises: Ai::Error::InvalidOutput.new("not JSON"))

    result = AiTestGeneration.new(transactions: transactions(8), family: @family).call

    assert_kind_of Ai::Error::InvalidOutput, result.error
    assert_equal 2 + 2 + 4, requests.size   # each route once, then halves, then quarters
    assert_not DebugLogEntry.exists?(category: "ai_generation", family: @family)
  end

  test "a configuration error isn't bisected" do
    requests = stub_ai(raises: Ai::Error::Unauthorized.new("bad key"))

    result = AiTestGeneration.new(transactions: transactions(4), family: @family).call

    assert_kind_of Ai::Error::Unauthorized, result.error
    assert_equal 2, requests.size
  end
end
