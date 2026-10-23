require "test_helper"

class BackgroundJobHealthTest < ActiveSupport::TestCase
  setup { Rails.cache.delete(BackgroundJobHealth::CACHE_KEY) }
  teardown { Rails.cache.delete(BackgroundJobHealth::CACHE_KEY) }

  test "healthy when a worker polls the critical queue with low latency" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "default", "ai_high_priority" ] } ], latency: 1.0)

    assert BackgroundJobHealth.healthy?
    assert_equal 1, BackgroundJobHealth.snapshot[:workers]
  end

  test "unhealthy when no workers are online" do
    stub_sidekiq(processes: [], latency: 0.0)

    assert_not BackgroundJobHealth.healthy?
  end

  test "unhealthy when the critical queue is not polled by any worker" do
    stub_sidekiq(processes: [ { "queues" => [ "default" ] } ], latency: 0.0)

    assert_not BackgroundJobHealth.healthy?
  end

  test "unhealthy when the critical queue is badly backed up" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "ai_high_priority" ] } ], latency: 9_999)

    assert_not BackgroundJobHealth.healthy?
  end

  test "unhealthy when no worker polls the chat queue" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority" ] } ], latency: 0.0)

    assert_not BackgroundJobHealth.healthy?
  end

  test "with one AI thread, a running ai_low_priority job is busy" do
    stub_running("ai_low_priority")

    assert BackgroundJobHealth.ai_busy?
  end

  test "with one AI thread, a running chat is busy for the next one" do
    stub_running("ai_high_priority")

    assert BackgroundJobHealth.ai_busy?
  end

  test "other running jobs aren't busy" do
    stub_running("default")

    assert_not BackgroundJobHealth.ai_busy?
  end

  test "busy can be limited to some AI queues" do
    stub_running("ai_high_priority")

    assert_not BackgroundJobHealth.ai_busy?(queues: [ "ai_low_priority" ])
  end

  test "with several AI threads, a running ai_low_priority job isn't busy" do
    stub_running("ai_low_priority", one_ai_thread: false)

    assert_not BackgroundJobHealth.ai_busy?
  end

  test "one AI thread when a worker process carries the label" do
    Sidekiq::ProcessSet.stubs(:new).with(false).returns([ stub(labels: [ BackgroundJobHealth::ONE_AI_THREAD_LABEL ]) ])
    assert BackgroundJobHealth.one_ai_thread?

    Sidekiq::ProcessSet.stubs(:new).with(false).returns([ stub(labels: []) ])
    assert_not BackgroundJobHealth.one_ai_thread?
  end

  test "a worker gets the label only when a capsule polls ai_low_priority with one thread" do
    config = Sidekiq::Config.new
    ai = config.capsule("ai") { |capsule| capsule.queues = %w[ai_high_priority ai_low_priority] }

    ai.concurrency = 1
    assert BackgroundJobHealth.one_ai_thread_worker?(config)

    ai.concurrency = 2
    assert_not BackgroundJobHealth.one_ai_thread_worker?(config)
  end

  test "fails open when Sidekiq/Redis is unreachable" do
    Sidekiq::ProcessSet.stubs(:new).raises(StandardError.new("no redis"))

    assert BackgroundJobHealth.healthy?
    assert BackgroundJobHealth.snapshot[:error]
  end

  private
    def stub_sidekiq(processes:, latency:)
      process_set = mock("ProcessSet")
      process_set.stubs(:size).returns(processes.size)
      process_set.stubs(:flat_map).returns(processes.flat_map { |p| p["queues"] })
      Sidekiq::ProcessSet.stubs(:new).returns(process_set)

      Sidekiq::Queue.stubs(:new).with("high_priority").returns(stub(latency: latency))
    end

    def stub_running(queue, one_ai_thread: true)
      BackgroundJobHealth.stubs(:one_ai_thread?).returns(one_ai_thread)
      Sidekiq::WorkSet.stubs(:new).returns([ [ "worker:1", "tid", stub(queue: queue) ] ])
    end
end
