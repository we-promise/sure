require "test_helper"

# The shadow gets the ids of the items the primary was sent, by object identity: a value-equal
# twin sent earlier isn't dropped because an unsent twin is in `remaining`.
class Ai::ShadowTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(categorization_shadow_rate: 1.0)
    use_ai_routes   # shadow_categorize on jev/jev-latest
  end

  test "the shadow is sent the sent items, keeping value-equal twins ahead of unsent twins" do
    twins = Array.new(2) { { id: "t1", classification: "Primary", description: "SAME", merchant: nil, amount: 1.0 } }
    generation = Ai::Generations::CategorizeTransactions.new(transactions: twins, categories: [], family: @family)
    route = Ai::Router.new(family: @family).resolve(:categorize).route
    result = Ai::Result.new(value: { categorizations: [] }, route:, remaining: [ twins.second ])

    enqueued = nil
    Ai::ShadowJob.stub(:perform_later, ->(*args) { enqueued = args }) do
      Ai::Shadow.enqueue(generation, result)
    end

    assert_equal [ "t1" ], enqueued[2][:items].keys, "the sent twin's id, though its unsent twin is in remaining"
  end

  test "the sampling rate is rolled against a number between zero and one" do
    @family.update!(categorization_shadow_rate: 0.5)
    txns = [ { id: "t1", classification: "Primary", description: "SHOP", merchant: nil, amount: 1.0 } ]
    generation = Ai::Generations::CategorizeTransactions.new(transactions: txns, categories: [], family: @family)
    route = Ai::Router.new(family: @family).resolve(:categorize).route
    result = Ai::Result.new(value: { categorizations: [] }, route:, remaining: [])

    enqueued = :absent
    Ai::Shadow.stubs(:rand).returns(0.4)
    Ai::ShadowJob.stub(:perform_later, ->(*args) { enqueued = args }) { Ai::Shadow.enqueue(generation, result) }
    assert_not_equal :absent, enqueued, "below the rate, the shadow runs"

    enqueued = :absent
    Ai::Shadow.stubs(:rand).returns(0.6)
    Ai::ShadowJob.stub(:perform_later, ->(*args) { enqueued = args }) { Ai::Shadow.enqueue(generation, result) }
    assert_equal :absent, enqueued
  end
end
