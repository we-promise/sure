require "test_helper"

class SidekiqHealthTest < ActiveSupport::TestCase
  def stub_sidekiq(processes: [], queues: [], stats: default_stats)
    Sidekiq::ProcessSet.stubs(:new).returns(processes)
    Sidekiq::Queue.stubs(:all).returns(queues)
    Sidekiq::Stats.stubs(:new).returns(stats)
  end

  def default_stats
    OpenStruct.new(enqueued: 0, failed: 0, processed: 0, retry_size: 0)
  end

  def fresh_process(beat_seconds_ago: 5)
    { "beat" => (Time.current - beat_seconds_ago.seconds).to_f }
  end

  def fake_queue(name: "default", size: 0, latency: 0.0)
    OpenStruct.new(name: name, size: size, latency: latency)
  end

  test "reports healthy when a worker is beating and no queue is backed up" do
    stub_sidekiq(
      processes: [ fresh_process ],
      queues: [ fake_queue ],
      stats: OpenStruct.new(enqueued: 0, failed: 0, processed: 100, retry_size: 0)
    )

    health = SidekiqHealth.new

    assert health.healthy?
    assert_nil health.reason
    assert_equal 1, health.processes_count
    assert_equal 100, health.processed_count
  end

  test "reports no_worker_processes when ProcessSet is empty" do
    stub_sidekiq(processes: [], queues: [])

    health = SidekiqHealth.new

    assert_not health.healthy?
    assert_equal :no_worker_processes, health.reason
    assert_equal 0, health.processes_count
    assert_nil health.last_heartbeat_at
  end

  test "reports stale_heartbeat when last beat is older than the timeout" do
    stub_sidekiq(
      processes: [ fresh_process(beat_seconds_ago: 10.minutes) ],
      queues: [ fake_queue ]
    )

    health = SidekiqHealth.new

    assert_not health.healthy?
    assert_equal :stale_heartbeat, health.reason
  end

  test "reports stale_heartbeat when a registered process has no heartbeat at all" do
    # Sidekiq's ProcessSet can return entries with a nil `beat` key during
    # startup or after a forced kill — treat it the same as a stale beat,
    # not as healthy.
    stub_sidekiq(
      processes: [ { "beat" => nil } ],
      queues: [ fake_queue ]
    )

    health = SidekiqHealth.new

    assert_not health.healthy?
    assert_equal :stale_heartbeat, health.reason
    assert_nil health.last_heartbeat_at
  end

  test "reports queue_backed_up when oldest job exceeds latency threshold" do
    stub_sidekiq(
      processes: [ fresh_process ],
      queues: [ fake_queue(size: 100, latency: 1.hour.to_f) ],
      stats: OpenStruct.new(enqueued: 100, failed: 0, processed: 50, retry_size: 0)
    )

    health = SidekiqHealth.new

    assert_not health.healthy?
    assert_equal :queue_backed_up, health.reason
  end

  test "reports redis_unreachable when Sidekiq raises a Redis connection error" do
    Sidekiq::ProcessSet.stubs(:new).raises(RedisClient::ConnectionError.new("Connection refused"))

    health = SidekiqHealth.new

    assert_not health.healthy?
    assert_equal :redis_unreachable, health.reason
    assert_equal 0, health.processes_count
    assert_equal 0.0, health.max_queue_latency
    assert_empty health.queue_breakdown
  end

  test "queue_breakdown returns sorted [name, size, latency] triples" do
    stub_sidekiq(
      processes: [ fresh_process ],
      queues: [ fake_queue(name: "b", size: 5, latency: 1.0), fake_queue(name: "a", size: 2, latency: 0.5) ],
      stats: OpenStruct.new(enqueued: 7, failed: 0, processed: 0, retry_size: 0)
    )

    health = SidekiqHealth.new

    assert_equal [ [ "a", 2, 0.5 ], [ "b", 5, 1.0 ] ], health.queue_breakdown
  end

  test "treats unexpected non-Redis exceptions as redis_unreachable rather than crashing" do
    Sidekiq::ProcessSet.stubs(:new).raises(StandardError.new("unexpected"))

    health = SidekiqHealth.new

    assert_not health.healthy?
    assert_equal :redis_unreachable, health.reason
  end

  test "current memoizes across calls inside the cache TTL" do
    with_memory_cache do
      stub_sidekiq(processes: [ fresh_process ], queues: [ fake_queue ])

      first = SidekiqHealth.current
      assert first.healthy?

      # If `current` re-queried Redis on the second call, raising from
      # ProcessSet would propagate through `load_state!`'s rescue and
      # flip `reason` to `:redis_unreachable`. The cached snapshot
      # should be returned instead — still healthy. We don't compare
      # object identity here: ActiveSupport::Cache::MemoryStore
      # Marshals values by default, so the second `fetch` returns an
      # `==`-equal but not `equal?`-identical instance.
      Sidekiq::ProcessSet.stubs(:new).raises(StandardError.new("would explode if re-queried"))
      second = SidekiqHealth.current

      assert second.healthy?
      assert_nil second.reason
    end
  end

  test "expire_cache! forces the next current call to re-query Redis" do
    with_memory_cache do
      stub_sidekiq(processes: [ fresh_process ], queues: [ fake_queue ])
      first = SidekiqHealth.current
      assert first.healthy?

      stub_sidekiq(processes: [], queues: [])
      SidekiqHealth.expire_cache!
      second = SidekiqHealth.current

      assert_not second.healthy?
      assert_equal :no_worker_processes, second.reason
    end
  end

  private
    # Stubs Rails.cache with an in-process MemoryStore for the duration
    # of the block so cache hit/miss behavior is actually exercised —
    # test env defaults to :null_store, which would skip every `fetch`
    # body and make caching invisible to assertions.
    def with_memory_cache
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      yield
    ensure
      Rails.unstub(:cache)
    end
end
