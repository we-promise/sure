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

  test "a model that refuses more than three items gets every item, by halving on the same route" do
    requests = stub_ai do |request|
      raise Ai::Error::ContextTooLong, "too long" if ids_in(request).size > 3

      AiTestGeneration.answer(request)
    end

    result = AiTestGeneration.new(transactions: transactions(10), family: @family).call

    assert_equal 10, result.value[:merchants].size
    assert(requests.all? { _1.model.endpoint.name == "gpu" })
    assert_equal 10, requests.select { ids_in(_1).size <= 3 }.sum { ids_in(_1).size }
  end

  test "an answer that stops at the output limit is split the same way" do
    stub_ai do |request|
      raise Ai::Error::OutputCut, "cut" if ids_in(request).size > 2

      AiTestGeneration.answer(request)
    end

    assert_equal 6, AiTestGeneration.new(transactions: transactions(6), family: @family).call.value[:merchants].size
  end

  test "a single item that can't fit escalates to the next route; the rest stay on the first" do
    requests = stub_ai do |request|
      ids = ids_in(request)
      raise Ai::Error::ContextTooLong, "too long" if request.model.endpoint.name == "gpu" && ids.include?("t2")

      AiTestGeneration.answer(request)
    end

    result = AiTestGeneration.new(transactions: transactions(4), family: @family).call

    assert_equal %w[t0 t1 t2 t3], result.value[:merchants].map { _1[:transaction_id] }.sort
    assert_equal [ %w[t2] ], requests.select { _1.model.endpoint.name == "openai" }.map { ids_in(_1) }
  end

  test "items that fit no route are left unanswered and logged, and the ones answered are kept" do
    stub_ai do |request|
      raise Ai::Error::ContextTooLong, "too long" if ids_in(request).include?("t2")

      AiTestGeneration.answer(request)
    end

    result = AiTestGeneration.new(transactions: transactions(4), family: @family).call

    assert result.success?
    assert_equal %w[t0 t1 t3], result.value[:merchants].map { _1[:transaction_id] }.sort
    entry = DebugLogEntry.find_by!(category: "ai_generation", family: @family)
    assert_equal "warn", entry.level
    assert_equal({ "feature" => "detect_merchants", "item_ids" => %w[t2] }, entry.metadata.slice("feature", "item_ids"))
  end
end
