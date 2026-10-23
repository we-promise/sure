require "test_helper"
require "sidekiq/capsule"

# Redis is stubbed: parallel test processes share one Redis, and other tests'
# chat jobs set the same global key.
class ChatReservationTest < ActiveSupport::TestCase
  test "with one AI thread, hold! reserves the AI thread for the TTL" do
    with_hold_redis do |redis|
      assert_equal 60, ChatReservation.hold!
      assert redis.key?(ChatReservation::KEY)
    end
  end

  test "back-to-back holds stop at the cap and resume a TTL later" do
    with_hold_redis do |redis|
      travel_to Time.zone.parse("2026-10-23 09:00:00")
      29.times { ChatReservation.hold!; travel 30.seconds }
      travel_to Time.zone.parse("2026-10-23 09:14:30")
      assert_equal 30, ChatReservation.hold!

      travel_to Time.zone.parse("2026-10-23 09:15:00")
      assert_nil ChatReservation.hold!
      assert_not redis.key?(ChatReservation::KEY)

      travel_to Time.zone.parse("2026-10-23 09:16:00")
      assert_equal 60, ChatReservation.hold!
    end
  end

  test "a hold that lapsed starts a new cap" do
    with_hold_redis do
      travel_to Time.zone.parse("2026-10-23 09:00:00")
      ChatReservation.hold!
      travel_to Time.zone.parse("2026-10-23 09:14:50")
      assert_equal 60, ChatReservation.hold!
    end
  end

  test "with several AI threads, hold! reserves nothing" do
    Sidekiq.expects(:redis).never

    with_env_overrides("RAILS_AI_MAX_THREADS" => "2") { assert_nil ChatReservation.hold! }
  end

  test "the bubble says busy while a background AI job runs, ready while some wait, else nothing" do
    ChatReservation.stubs(:chat_active?).returns(false)
    BackgroundJobHealth.stubs(:ai_busy?).returns(false)
    Sidekiq::Queue.stubs(:new).with("ai_low_priority").returns(stub(size: 0))
    assert_nil ChatReservation.bubble(60)

    Sidekiq::Queue.stubs(:new).with("ai_low_priority").returns(stub(size: 2))
    assert_equal({ seconds: 60, busy: false }, ChatReservation.bubble(60))

    BackgroundJobHealth.stubs(:ai_busy?).returns(true)
    assert_equal({ seconds: 60, busy: true }, ChatReservation.bubble(60))
    assert_nil ChatReservation.bubble(nil)
  end

  test "no bubble while a chat is queued or running" do
    ChatReservation.stubs(:chat_active?).returns(true)
    BackgroundJobHealth.stubs(:ai_busy?).returns(true)

    assert_nil ChatReservation.bubble(60)
  end

  test "a running chat counts as active until its job ends, even if it raises" do
    conn = mock
    conn.expects(:call).with("SET", ChatReservation::CHAT_KEY, "1", "EX", Chat.response_timeout.to_i)
    conn.expects(:call).with("DEL", ChatReservation::CHAT_KEY)
    Sidekiq.stubs(:redis).yields(conn)

    assert_raises(RuntimeError) { ChatReservation.while_chat_runs { raise "boom" } }
  end

  test "the AI capsule skips ai_low_priority while a reservation is held" do
    fetch = fetch_for(%w[ai_high_priority ai_low_priority])

    stub_reservation(fetch, held: false)
    assert_equal %w[queue:ai_high_priority queue:ai_low_priority], fetch.queues_cmd

    stub_reservation(fetch, held: true)
    assert_equal %w[queue:ai_high_priority], fetch.queues_cmd
  end

  test "other capsules' queues are left alone" do
    fetch = fetch_for(%w[high_priority default])
    fetch.expects(:redis).never

    assert_equal %w[queue:high_priority queue:default], fetch.queues_cmd
  end

  private
    # Redis with expiring keys, enough for hold!.
    class FakeRedis
      def initialize
        @data = {}
      end

      def key?(key)
        expire(key)
        @data.key?(key)
      end

      def call(command, key, *args)
        expire(key)
        case command
        when "GET" then @data.dig(key, :value)
        when "EXISTS" then @data.key?(key) ? 1 : 0
        when "SET" then @data[key] = { value: args[0].to_s, expires_at: Time.current + args[2].to_i }
        end
      end

      private
        def expire(key)
          @data.delete(key) if @data.key?(key) && @data[key][:expires_at] <= Time.current
        end
    end

    def with_hold_redis
      redis = FakeRedis.new
      Sidekiq.stub(:redis, ->(&block) { block.call(redis) }) do
        with_env_overrides("RAILS_AI_MAX_THREADS" => nil) { yield redis }
      end
    end

    def fetch_for(queues)
      capsule = Sidekiq::Capsule.new("test", Sidekiq.default_configuration)
      capsule.queues = queues
      ChatReservation::Fetch.new(capsule)
    end

    def stub_reservation(fetch, held:)
      conn = mock
      conn.expects(:call).with("EXISTS", ChatReservation::KEY)
      fetch.expects(:redis).yields(conn).returns(held ? 1 : 0)
    end
end
