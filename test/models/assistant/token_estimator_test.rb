require "test_helper"

class Assistant::TokenEstimatorTest < ActiveSupport::TestCase
  test "estimate is zero for nil or empty" do
    assert_equal 0, Assistant::TokenEstimator.estimate(nil)
    assert_equal 0, Assistant::TokenEstimator.estimate("")
    assert_equal 0, Assistant::TokenEstimator.estimate([])
  end

  test "estimate applies chars/4 with safety factor for strings" do
    # 100 chars / 4 = 25 tokens, × 1.25 safety factor, ceil = 32
    assert_equal 32, Assistant::TokenEstimator.estimate("a" * 100)
  end

  test "estimate sums across arrays" do
    # Use lengths that avoid ceil rounding drift: 80 chars → 20 tokens → 25.0 ceil → 25.
    string_estimate = Assistant::TokenEstimator.estimate("a" * 80)
    array_estimate  = Assistant::TokenEstimator.estimate([ "a" * 80, "a" * 80 ])

    assert_equal string_estimate * 2, array_estimate
  end

  test "estimate serializes hashes via JSON" do
    hash = { role: "assistant", content: "hi" }
    # {"role":"assistant","content":"hi"} => 35 chars / 4 × 1.25 ceil = 11
    assert_equal 11, Assistant::TokenEstimator.estimate(hash)
  end

  test "estimate handles nested structures" do
    nested = [ { role: "user", content: "hello" }, { role: "assistant", content: "world" } ]
    # Each hash gets JSON-serialized and summed
    expected = nested.sum { |h| Assistant::TokenEstimator.estimate(h) }
    assert_equal expected, Assistant::TokenEstimator.estimate(nested)
  end

  test "estimate coerces unknown types via to_s" do
    assert Assistant::TokenEstimator.estimate(12345) > 0
    assert Assistant::TokenEstimator.estimate(:symbol) > 0
  end
end
