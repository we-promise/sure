require "test_helper"

class Ai::GenerationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b])
  end

  def transactions(count) = Array.new(count) { |i| { id: "t#{i}", description: "SHOP #{i}", merchant: nil } }

  def generation(count, **) = AiTestGeneration.new(transactions: transactions(count), family: @family, **)

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

  test "batches by the model's batch size; call(batches: 1) leaves the rest as remaining" do
    with_ai_model_settings(batch_size: 2) do
      requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

      one = generation(5).call(batches: 1)
      assert_equal %w[t0 t1], one.value[:merchants].map { _1[:transaction_id] }
      assert_equal %w[t2 t3 t4], one.remaining_ids

      all = generation(5).call
      assert_equal 5, all.value[:merchants].size
      assert_empty all.remaining
      assert_equal 4, requests.size
    end
  end

  test "a model's context window caps a batch by tokens, the rendered prompt included" do
    with_ai_model_settings(context_window: 1_000, max_output_tokens: 100) do
      requests = stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

      result = generation(30).call

      assert_equal 30, result.value[:merchants].size
      assert_operator requests.size, :>, 1
      sizes = requests.map { _1.input.scan("- ID:").size }
      assert_operator sizes.max, :<, 25
      assert_operator sizes.max, :>, 1
    end
  end

  test "an unavailable feature returns its reason, and call! raises it" do
    without_ai do
      result = generation(1).call

      assert result.unavailable?
      assert_equal :not_configured, result.availability.reason
      assert_raises(Ai::Error::Unavailable) { generation(1).call! }
    end
  end

  test "cancelled stops before the next batch" do
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }

    result = generation(3).call(cancelled: -> { true })

    assert result.cancelled?
  end

  test "an error after every route is the result's error, and call! raises it" do
    stub_ai(:detect_merchants, raises: Ai::Error::Refused.new("bad request", status: 400))

    assert_kind_of Ai::Error::Refused, generation(1).call.error
    assert_raises(Ai::Error::Refused) { generation(1).call! }
  end
end
