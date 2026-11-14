require "test_helper"

class Ai::DownMarksTest < ActiveSupport::TestCase
  test "a rejected credential's mark changes with the key or a static header, so a fix isn't skipped" do
    endpoint = ai_endpoint(name: "gateway", api_key: "k1", extra_headers: { "X-Gateway-Key" => "old" })

    original = Ai::DownMarks.key_key(endpoint)

    assert_not_equal original, Ai::DownMarks.key_key(endpoint.with(api_key: "k2"))
    assert_not_equal original, Ai::DownMarks.key_key(endpoint.with(extra_headers: { "X-Gateway-Key" => "new" }))
    assert_equal original, Ai::DownMarks.key_key(endpoint.with(timeout_seconds: 5))
  end

  test "a model's mark is for that model on that credential" do
    route = Ai::Route.new(feature: :categorize, model: ai_model(endpoint: ai_endpoint(name: "gateway", api_key: "k1")))
    replaced = Ai::Route.new(feature: :categorize, model: route.model.with(endpoint: route.endpoint.with(api_key: "k2")))

    assert_not_equal Ai::DownMarks.model_key(route), Ai::DownMarks.model_key(replaced)
  end

  test "a route down for a timeout is passing; one down for a bad key isn't" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    timed_out = Ai::Route.new(feature: :categorize, model: ai_model(endpoint: ai_endpoint(name: "slow")))
    rejected = Ai::Route.new(feature: :categorize, model: ai_model(endpoint: ai_endpoint(name: "bad")))

    Ai::DownMarks.mark(timed_out, Ai::Error::Timeout.new("slow"))
    Ai::DownMarks.mark(rejected, Ai::Error::Unauthorized.new("401"))

    assert Ai::DownMarks.passing?(timed_out)
    assert_not Ai::DownMarks.passing?(rejected)
  end

  test "a route's state comes from one read of each mark, so one expiring mid-check can't split down from why" do
    Rails.stubs(:cache).returns(cache = ActiveSupport::Cache::MemoryStore.new)
    route = Ai::Route.new(feature: :categorize, model: ai_model(endpoint: ai_endpoint(name: "slow")))
    cache.stubs(:read).returns(nil)
    cache.stubs(:read).with(Ai::DownMarks.model_key(route)).returns("Timeout").then.returns(nil)

    assert_equal :passing, Ai::DownMarks.state(route)
    assert_equal :up, Ai::DownMarks.state(route), "the mark has expired"
  end

  test "two servers that share an endpoint name, a key and a model don't share a mark" do
    one = Ai::Route.new(feature: :categorize, model: ai_model(name: "qwen3", endpoint: ai_endpoint(name: "openai_compatible", api_key: "k", base_url: "http://a.lan:8080/v1")))
    other = Ai::Route.new(feature: :categorize, model: one.model.with(endpoint: one.endpoint.with(base_url: "http://b.lan:8080/v1")))

    assert_not_equal Ai::DownMarks.model_key(one), Ai::DownMarks.model_key(other)
    assert_not_equal Ai::DownMarks.key_key(one.endpoint), Ai::DownMarks.key_key(other.endpoint)
  end
end
