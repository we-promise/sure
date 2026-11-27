require "test_helper"

class LlmUsage::CallTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.llm_usages.delete_all
  end

  test "requests sharing a call id are one call; rows without one are calls of their own" do
    call_id = SecureRandom.uuid
    usage(call_id:, status: "failed", created_at: 3.minutes.ago, estimated_cost: nil, metadata: { "error" => "busy" })
    usage(call_id:, status: "succeeded", created_at: 2.minutes.ago, estimated_cost: 0.002)
    legacy = usage(created_at: 1.minute.ago, estimated_cost: 0.001)

    calls = @family.llm_usages.recent_calls

    assert_equal [ legacy.id, call_id ], calls.map(&:id)
    retried = calls.last
    assert retried.multiple_requests?
    assert_equal 2, retried.requests_count
    assert_equal "succeeded", retried.status, "a call whose retry succeeded succeeded"
    assert_equal 200, retried.prompt_tokens
    assert_in_delta 0.002, retried.estimated_cost
    assert_not calls.first.multiple_requests?
  end

  test "stored costs are summed as stored; statistics never reprice a row" do
    usage(estimated_cost: 3.21)
    LlmUsage.stubs(:calculate_cost).raises("a stored cost is never recalculated")

    stats = LlmUsage.statistics_for_family(@family)

    assert_in_delta 3.21, stats[:total_cost], 0.001
  end

  test "the average cost comes from the unrounded total, over priced calls only" do
    usage(estimated_cost: 0.002)
    usage(estimated_cost: nil)

    assert_in_delta 0.002, LlmUsage.statistics_for_family(@family)[:avg_cost], 0.00001
  end

  private
    def usage(**attributes)
      @family.llm_usages.create!(provider: "openai", model: "gpt-4.1", operation: "bill_setup", prompt_tokens: 100,
                                 completion_tokens: 10, total_tokens: 110, **attributes)
    end
end
