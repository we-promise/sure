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

  test "statistics count calls, not requests" do
    call_id = SecureRandom.uuid
    2.times { usage(call_id:, estimated_cost: 0.01) }
    usage(estimated_cost: 0.02)

    stats = LlmUsage.statistics_for_family(@family)

    assert_equal 2, stats[:total_calls]
    assert_equal 3, stats[:total_requests]
    assert_equal 2, stats[:calls_with_cost]
    assert_in_delta 0.02, stats[:avg_cost]
  end

  test "a row the old recorders write with an error in metadata is a failed request" do
    row = usage(metadata: { "error" => "HTTP 500", "http_status_code" => 500 })

    assert row.failed?
    assert_equal "HTTP 500", row.error_message
    row.status = "exploded"
    assert_not row.valid?
  end

  private
    def usage(**attributes)
      @family.llm_usages.create!(provider: "openai", model: "gpt-4.1", operation: "bill_setup", prompt_tokens: 100,
                                 completion_tokens: 10, total_tokens: 110, **attributes)
    end
end
