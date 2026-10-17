require "test_helper"

class Provider::Openai::BatchSlicerTest < ActiveSupport::TestCase
  test "returns empty array for empty input" do
    assert_equal [], Provider::Openai::BatchSlicer.call([], max_tokens: 2000)
  end

  test "single batch when within the token budget" do
    items = Array.new(10) { |i| { id: i, name: "Item#{i}" } }

    batches = Provider::Openai::BatchSlicer.call(items, max_tokens: 10_000)

    assert_equal 1, batches.size
    assert_equal items, batches.first
  end

  test "splits on token budget" do
    big_item = { payload: "x" * 200 }  # ~63 tokens each
    items = Array.new(10) { big_item }

    # ~125-token budget fits 2 items per batch
    batches = Provider::Openai::BatchSlicer.call(items, max_tokens: 125)

    assert batches.size > 1
    assert_equal items, batches.flatten
    batches.each do |batch|
      tokens = Assistant::TokenEstimator.estimate(batch)
      assert tokens <= 125, "Batch exceeded token budget: #{tokens}"
    end
  end

  test "raises ContextOverflowError when single item exceeds budget" do
    huge = { payload: "x" * 10_000 }

    assert_raises Provider::Openai::BatchSlicer::ContextOverflowError do
      Provider::Openai::BatchSlicer.call([ huge ], max_tokens: 500)
    end
  end

  test "raises ContextOverflowError when fixed_tokens exceed budget" do
    assert_raises Provider::Openai::BatchSlicer::ContextOverflowError do
      Provider::Openai::BatchSlicer.call([ { a: 1 } ], max_tokens: 500, fixed_tokens: 600)
    end
  end

  test "respects fixed_tokens when computing available budget" do
    items = Array.new(5) { { payload: "x" * 80 } }  # ~25 tokens each

    # Budget of 200 minus fixed 100 = 100 available; fits ~4 items per batch
    batches = Provider::Openai::BatchSlicer.call(items, max_tokens: 200, fixed_tokens: 100)

    assert batches.size >= 2
    assert_equal items, batches.flatten
  end

  test "never produces empty batches" do
    items = Array.new(7) { { payload: "x" * 80 } }  # ~25 tokens each

    batches = Provider::Openai::BatchSlicer.call(items, max_tokens: 60)

    batches.each { |b| assert b.any?, "Empty batch produced" }
  end
end
