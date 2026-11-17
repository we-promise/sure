require "test_helper"

class Ai::GenerationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b])
  end

  def transactions(count) = Array.new(count) { |i| { id: "t#{i}", description: "SHOP #{i}", merchant: nil } }

  def generation(count, **) = AiTestGeneration.new(transactions: transactions(count), family: @family, **)

  def answered_ids(result) = result.value[:merchants].map { _1[:transaction_id] }

  test "renders the route's prompt, sends the schema and the route's settings, and coerces the answer" do
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    result = generation(2).call

    assert result.success?
    assert_equal %w[t0 t1], result.value[:merchants].map { _1[:transaction_id] }
    assert_equal "gpu", result.route.endpoint.name
    request = requests.first
    assert_includes request.input, "- ID: t0, Description: \"SHOP 0\""
    assert_equal "test_items", request.schema_name
    assert_equal :auto, request.json_mode
    assert_equal 0.0, request.failed_ratio.call(AiTestGeneration.answer(request).deep_stringify_keys)
  end

  test "the blank share counts each item once, so repeated answers don't hide missing ones" do
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
    generation(3).call
    repeated = { "merchants" => Array.new(3) { { "transaction_id" => "t0", "business_name" => "Shop", "business_url" => nil } } }

    assert_in_delta 2 / 3.0, requests.first.failed_ratio.call(repeated)
  end

  test "use_ai_model_settings keeps the routes an earlier use_ai_routes set" do
    use_ai_model_settings(batch_size: 2)

    assert_equal %w[gpu], Ai::Config.current.routes_for(:detect_merchants).map { _1.endpoint.name }
  end

  test "batches by the model's batch size; call(batches: 1) leaves the rest as remaining" do
    use_ai_model_settings(batch_size: 2)
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    one = generation(5).call(batches: 1)
    assert_equal %w[t0 t1], one.value[:merchants].map { _1[:transaction_id] }
    assert_equal %w[t2 t3 t4], one.remaining_ids

    all = generation(5).call
    assert_equal 5, all.value[:merchants].size
    assert_empty all.remaining
    assert_equal 4, requests.size
  end

  test "a model's context window caps a batch by tokens, the rendered prompt included" do
    use_ai_model_settings(context_window: 1_000, max_output_tokens: 100)
    requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    result = generation(30).call

    assert_equal 30, result.value[:merchants].size
    assert_operator requests.size, :>, 1
    sizes = requests.map { _1.input.scan("- ID:").size }
    assert_operator sizes.max, :<, 25
    assert_operator sizes.max, :>, 1
  end

  test "an unavailable feature returns its reason, and call! raises it" do
    use_no_ai
    result = generation(1).call

    assert result.unavailable?
    assert_equal :not_configured, result.availability.reason
    assert_raises(Ai::Error::Unavailable) { generation(1).call! }
  end

  test "cancelled stops before the next batch" do
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    result = generation(3).call(cancelled: -> { true })

    assert result.cancelled?
  end

  test "items left over when the next route times out stay remaining, for a later job to retry" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::Timeout, "slow" if request.model.endpoint.name == "openai"
      raise Ai::Error::ContextTooLong, "too long" unless request.input.include?("t0") && !request.input.include?("t1")

      AiTestGeneration.answer(request)
    end

    result = generation(3).call

    assert_equal %w[t0], result.value[:merchants].map { _1[:transaction_id] }
    assert_equal %w[t1 t2], result.remaining_ids.sort
  end

  test "an error after every route is the result's error, and call! raises it" do
    stub_ai(:detect_merchants, raises: Ai::Error::Refused.new("bad request", status: 400))

    assert_kind_of Ai::Error::Refused, generation(1).call.error
    assert_raises(Ai::Error::Refused) { generation(1).call! }
  end

  test "a fallback with a smaller batch_size takes the batch in pieces of that size" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    use_ai_model_settings("openai/gpt-4.1-mini", batch_size: 2)
    requests = stub_ai(:detect_merchants) do |request|
      raise Ai::Error::Timeout, "slow" if request.model.endpoint.name == "gpu"

      AiTestGeneration.answer(request)
    end

    result = generation(5).call(batches: 1)

    assert_equal %w[t0 t1 t2 t3 t4], answered_ids(result)
    assert_equal [ 5, 2, 2, 1 ], requests.map { _1.input.scan("- ID:").size }
  end

  test "an item no route can fit is skipped and logged, and the items after it still run" do
    use_ai_model_settings(batch_size: 1)
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::ContextTooLong, "too long" if request.input.include?("t0")

      AiTestGeneration.answer(request)
    end

    one = generation(3).call(batches: 1)
    assert one.success?
    assert_empty answered_ids(one)
    assert_equal %w[t1 t2], one.remaining_ids

    assert_difference -> { DebugLogEntry.where(message: "Items no route could answer were left unanswered").count } do
      assert_equal %w[t1 t2], answered_ids(generation(3).call)
    end
  end

  test "unusable answers skip a batch once another has worked, and fail the call before that" do
    use_ai_model_settings(batch_size: 1)
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::InvalidOutput, "garbage" if request.input.include?("t1")

      AiTestGeneration.answer(request)
    end

    assert_equal %w[t0 t2], answered_ids(generation(3).call)
    starting_at_t1 = AiTestGeneration.new(transactions: transactions(3).drop(1), family: @family)
    assert_kind_of Ai::Error::InvalidOutput, starting_at_t1.call.error
  end

  test "a timeout while bisecting keeps the halves already answered and leaves the rest for later" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    stub_ai(:detect_merchants) do |request|
      ids = request.input.scan(/ID: (t\d)/).flatten
      raise Ai::Error::InvalidOutput, "garbage" if ids.size > 2 || request.model.endpoint.name == "openai"
      raise Ai::Error::Timeout, "slow" if ids.include?("t2")

      AiTestGeneration.answer(request)
    end

    result = generation(4).call

    assert_equal %w[t0 t1], answered_ids(result)
    assert_equal %w[t2 t3], result.remaining_ids
    assert_equal %w[gpu], result.failed_over_from.map { _1.endpoint.name }
  end

  test "items a route can't fit wait for an escalation route that is only marked down" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    Ai::DownMarks.stubs(:state).returns(:up)
    Ai::DownMarks.stubs(:state).with { _1.endpoint.name == "openai" }.returns(:failing)
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::ContextTooLong, "too long" if request.input.include?("t1")

      AiTestGeneration.answer(request)
    end

    result = generation(2).call(batches: 1)

    assert_equal %w[t0], answered_ids(result)
    assert_equal %w[t1], result.remaining_ids
  end

  test "a timeout on a later piece keeps the pieces answered and sends the rest to the next route" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    requests = stub_ai(:detect_merchants) do |request|
      ids = request.input.scan(/ID: (t\d)/).flatten
      if request.model.endpoint.name == "gpu"
        raise Ai::Error::ContextTooLong, "too long" if ids.size > 1
        raise Ai::Error::Timeout, "slow" if ids == %w[t1]
      end

      AiTestGeneration.answer(request)
    end

    result = generation(2).call

    assert_equal %w[t0 t1], answered_ids(result).sort
    assert_empty result.remaining
    assert_equal %w[gpu], result.failed_over_from.map { _1.endpoint.name }
    fallback = requests.select { _1.model.endpoint.name == "openai" }
    assert_equal [ %w[t1] ], fallback.map { _1.input.scan(/ID: (t\d)/).flatten }, "t0 was answered already"
  end

  test "an unusable answer on a later piece keeps the pieces answered and escalates only the rest" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    requests = stub_ai(:detect_merchants) do |request|
      ids = request.input.scan(/ID: (t\d)/).flatten
      if request.model.endpoint.name == "gpu"
        raise Ai::Error::ContextTooLong, "too long" if ids.size > 1
        raise Ai::Error::InvalidOutput, "garbage" if ids == %w[t1]
      end

      AiTestGeneration.answer(request)
    end

    result = generation(2).call

    assert_equal %w[t0 t1], answered_ids(result).sort
    assert_empty result.failed_over_from.to_a, "an unusable answer marks nothing down"
    fallback = requests.select { _1.model.endpoint.name == "openai" }
    assert_equal [ %w[t1] ], fallback.map { _1.input.scan(/ID: (t\d)/).flatten }, "t0 was answered already"
  end

  [ %w[gpu/qwen3-8b openai/gpt-4.1-mini], %w[openai/gpt-4.1-mini gpu/qwen3-8b] ].each do |routes|
    test "an item one route can't fit while #{routes.first.split("/").first} first and the other times out is retried, not skipped" do
      use_ai_routes(detect_merchants: routes)
      stub_ai(:detect_merchants) do |request|
        raise Ai::Error::Timeout, "slow" if request.model.endpoint.name == "gpu"

        raise Ai::Error::ContextTooLong, "too long"
      end

      assert_kind_of Ai::Error::Timeout, generation(1).call(batches: 1).error
    end
  end

  test "an item the fallback can't fit waits when the primary is down for a passing failure" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    gpu = ->(route) { route.endpoint.name == "gpu" }
    Ai::DownMarks.stubs(:state).returns(:up)
    Ai::DownMarks.stubs(:state).with(&gpu).returns(:passing)
    stub_ai(:detect_merchants) { raise Ai::Error::ContextTooLong, "too long" }

    assert_kind_of Ai::Error::Unreachable, generation(1).call(batches: 1).error
  end

  test "a fallback that can't fit the batch doesn't stop bisecting the route whose answer was unusable" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::ContextTooLong, "too long" if request.model.endpoint.name == "openai"
      raise Ai::Error::InvalidOutput, "garbage" if request.input.scan("- ID:").size > 2

      AiTestGeneration.answer(request)
    end

    assert_equal %w[t0 t1 t2 t3], answered_ids(generation(4).call)
  end

  test "an unusable answer that bisection can't fix still fails the call, though a fallback couldn't fit it" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::ContextTooLong, "too long" if request.model.endpoint.name == "openai"

      raise Ai::Error::InvalidOutput, "garbage"
    end

    assert_kind_of Ai::Error::InvalidOutput, generation(2).call.error
  end

  test "a piece whose answer is unusable after another piece answered is still bisected" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b])
    stub_ai(:detect_merchants) do |request|
      ids = request.input.scan(/ID: (t\d)/).flatten
      raise Ai::Error::ContextTooLong, "too long" if ids.size > 2
      raise Ai::Error::InvalidOutput, "garbage" if ids == %w[t2 t3]

      AiTestGeneration.answer(request)
    end

    assert_equal %w[t0 t1 t2 t3], answered_ids(generation(4).call).sort
  end

  test "an unusable first piece doesn't stop the route answering the pieces after it" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    requests = stub_ai(:detect_merchants) do |request|
      ids = request.input.scan(/ID: (t\d)/).flatten
      if request.model.endpoint.name == "gpu"
        raise Ai::Error::ContextTooLong, "too long" if ids.size > 1
        raise Ai::Error::InvalidOutput, "garbage" if ids == %w[t0]
      end

      AiTestGeneration.answer(request)
    end

    result = generation(2).call

    assert_equal %w[t0 t1], answered_ids(result).sort
    fallback = requests.select { _1.model.endpoint.name == "openai" }
    assert_equal [ %w[t0] ], fallback.map { _1.input.scan(/ID: (t\d)/).flatten }, "gpu answered t1"
  end

  test "stub_ai fails the test when another feature calls, even under code that rescues errors" do
    stub_ai(:categorize) { flunk "not reached" }

    assert_raises(Minitest::Assertion) do
      generation(1).call
    rescue StandardError
      nil   # what a runner that records errors does
    end
  end

  test "an empty answer list for a batch is unusable, not a batch answered with nothing" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b])
    stub_ai(:detect_merchants, returns: { merchants: [] })

    assert_kind_of Ai::Error::InvalidOutput, generation(2).call.error
  end

  test "a bad key on the primary outranks a fallback that can't fit, so the requester hears of it" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    stub_ai(:detect_merchants) do |request|
      raise Ai::Error::Unauthorized, "bad key" if request.model.endpoint.name == "gpu"

      raise Ai::Error::ContextTooLong, "too long"
    end

    assert_kind_of Ai::Error::Unauthorized, generation(1).call(batches: 1).error
  end

  test "a primary marked down for a failure that needs a fix outranks a fallback that can't fit" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    Ai::DownMarks.stubs(:state).returns(:up)
    Ai::DownMarks.stubs(:state).with { _1.endpoint.name == "gpu" }.returns(:failing)
    stub_ai(:detect_merchants) { raise Ai::Error::ContextTooLong, "too long" }

    assert_kind_of Ai::Error::Refused, generation(1).call(batches: 1).error
  end

  test "every route marked down for a failure that needs a fix is refused, so the job doesn't retry a bad key" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    Ai::DownMarks.stubs(:state).returns(:failing)
    stub_ai(:detect_merchants) { flunk "no route should be called" }

    assert_kind_of Ai::Error::Refused, generation(1).call(batches: 1).error
  end

  test "routes all marked down for a passing failure stay unreachable, so the job retries" do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    Ai::DownMarks.stubs(:state).returns(:passing)
    stub_ai(:detect_merchants) { flunk "no route should be called" }

    assert_kind_of Ai::Error::Unreachable, generation(1).call(batches: 1).error
  end

  test "an item the answer leaves out is logged as unanswered, while the rest of the batch is kept" do
    stub_ai(:detect_merchants) { |request| AiTestGeneration.answer(request).tap { _1[:merchants].pop } }

    result = nil
    assert_difference -> { DebugLogEntry.where(message: "Items no route could answer were left unanswered").count } do
      result = generation(2).call
    end

    assert_equal %w[t0], answered_ids(result)
    assert_equal [ "t1" ], DebugLogEntry.order(:created_at).last.metadata["item_ids"]
  end
end
