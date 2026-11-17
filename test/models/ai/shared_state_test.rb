require "test_helper"

class Ai::SharedStateTest < ActiveSupport::TestCase
  test "values round-trip as JSON and expire" do
    Ai::SharedState.write("ai/test", { "status" => "passing", "codes" => [ 1, 2 ] }, expires_in: 1.minute)

    assert_equal({ "status" => "passing", "codes" => [ 1, 2 ] }, Ai::SharedState.read("ai/test"))
    travel 61.seconds
    assert_nil Ai::SharedState.read("ai/test")
  end

  test "delete removes a value; a missing key reads nil" do
    Ai::SharedState.write("ai/test", [ 1 ], expires_in: 1.minute)
    Ai::SharedState.delete("ai/test")

    assert_nil Ai::SharedState.read("ai/test")
    assert_nil Ai::SharedState.read("ai/never-written")
  end

  test "the Redis store sets a value with its expiry in Sidekiq's Redis" do
    redis = mock
    redis.expects(:call).with("SET", "ai/test", "[1]", "EX", 120)
    redis.expects(:call).with("GET", "ai/test").returns("[1]")
    redis.expects(:call).with("DEL", "ai/test")
    Sidekiq.stubs(:redis).yields(redis).returns("[1]")
    Ai::SharedState.store = Ai::SharedState::RedisStore.new

    Ai::SharedState.write("ai/test", [ 1 ], expires_in: 2.minutes)
    assert_equal [ 1 ], Ai::SharedState.read("ai/test")
    Ai::SharedState.delete("ai/test")
  end
end
