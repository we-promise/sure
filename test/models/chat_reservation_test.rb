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
    BackgroundJobHealth.stubs(:one_ai_thread?).returns(false)
    Sidekiq.expects(:redis).never

    assert_nil ChatReservation.hold!
  end

  test "the bubble says busy while a background AI job runs, ready while some wait, else nothing" do
    BackgroundJobHealth.expects(:one_ai_thread?).never
    ChatReservation.stubs(:chat_active?).returns(false)
    BackgroundJobHealth.stubs(:ai_job_running?).with(queues: [ "ai_low_priority" ]).returns(false)
    Sidekiq::Queue.stubs(:new).with("ai_low_priority").returns(stub(size: 0))
    assert_nil ChatReservation.bubble(60)

    Sidekiq::Queue.stubs(:new).with("ai_low_priority").returns(stub(size: 2))
    assert_equal({ seconds: 60, busy: false }, ChatReservation.bubble(60))

    BackgroundJobHealth.stubs(:ai_job_running?).with(queues: [ "ai_low_priority" ]).returns(true)
    assert_equal({ seconds: 60, busy: true }, ChatReservation.bubble(60))
    assert_nil ChatReservation.bubble(nil)
  end

  test "no bubble while a chat is queued or running" do
    ChatReservation.stubs(:chat_active?).returns(true)
    BackgroundJobHealth.stubs(:ai_job_running?).returns(true)

    assert_nil ChatReservation.bubble(60)
  end

  test "a running chat counts as active until its job ends, even if it raises" do
    conn = mock
    conn.expects(:call).with("SET", ChatReservation::CHAT_KEY, "1", "EX", Chat.response_timeout.to_i)
    conn.expects(:call).with("DEL", ChatReservation::CHAT_KEY)
    Sidekiq.stubs(:redis).yields(conn)

    assert_raises(RuntimeError) { ChatReservation.while_chat_runs { raise "boom" } }
  end

  test "a Redis error while setting the chat flag doesn't skip the reply" do
    conn = mock
    conn.stubs(:call).with("SET", ChatReservation::CHAT_KEY, "1", "EX", Chat.response_timeout.to_i).raises(RedisClient::ConnectionError)
    conn.stubs(:call).with("DEL", ChatReservation::CHAT_KEY)
    Sidekiq.stubs(:redis).yields(conn)

    assert_equal :reply, ChatReservation.while_chat_runs { :reply }
  end

  test "a reply isn't failed by a Redis error while clearing the chat flag" do
    conn = mock
    conn.stubs(:call).with("SET", ChatReservation::CHAT_KEY, "1", "EX", Chat.response_timeout.to_i)
    conn.stubs(:call).with("DEL", ChatReservation::CHAT_KEY).raises(RedisClient::ConnectionError)
    Sidekiq.stubs(:redis).yields(conn)

    assert_equal :reply, ChatReservation.while_chat_runs { :reply }
  end

  test "the AI capsule skips ai_low_priority while a reservation is held" do
    fetch = fetch_for(%w[ai_high_priority ai_low_priority])

    ChatReservation.stubs(:held?).returns(false)
    assert_equal %w[queue:ai_high_priority queue:ai_low_priority], fetch.queues_cmd

    ChatReservation.stubs(:held?).returns(true)
    assert_equal %w[queue:ai_high_priority], fetch.queues_cmd
  end

  test "other capsules' queues are left alone" do
    fetch = fetch_for(%w[high_priority default])
    ChatReservation.expects(:held?).never

    assert_equal %w[queue:high_priority queue:default], fetch.queues_cmd
  end

  test "an AI capsule with several threads ignores the reservation" do
    fetch = fetch_for(%w[ai_high_priority ai_low_priority], concurrency: 2)
    ChatReservation.stubs(:held?).returns(true)

    assert_equal %w[queue:ai_high_priority queue:ai_low_priority], fetch.queues_cmd
  end

  test "an ai_low_priority job popped after a hold started goes back to its queue" do
    fetch = fetch_for(%w[ai_high_priority ai_low_priority])
    work = Sidekiq::BasicFetch::UnitOfWork.new("queue:ai_low_priority", "{}", nil)
    Sidekiq::BasicFetch.any_instance.stubs(:retrieve_work).returns(work)

    ChatReservation.stubs(:held?).returns(true)
    work.expects(:requeue)
    assert_nil fetch.retrieve_work

    ChatReservation.stubs(:held?).returns(false)
    work.expects(:requeue).never
    assert_equal work, fetch.retrieve_work
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
      BackgroundJobHealth.stubs(:one_ai_thread?).returns(true)
      Sidekiq.stub(:redis, ->(&block) { block.call(redis) }) { yield redis }
    end

    def fetch_for(queues, concurrency: 1)
      capsule = Sidekiq::Capsule.new("test", Sidekiq.default_configuration)
      capsule.queues = queues
      capsule.concurrency = concurrency
      ChatReservation::Fetch.new(capsule)
    end
end
