require "test_helper"

class BackgroundJobHealthTest < ActiveSupport::TestCase
  setup { Rails.cache.delete(BackgroundJobHealth::CACHE_KEY) }
  teardown { Rails.cache.delete(BackgroundJobHealth::CACHE_KEY) }

  test "healthy when a worker polls the critical queue with low latency" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "default" ] } ], latency: 1.0)

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
    stub_sidekiq(processes: [ { "queues" => [ "high_priority" ] } ], latency: 9_999)

    assert_not BackgroundJobHealth.healthy?
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

      queue = mock("Queue")
      queue.stubs(:latency).returns(latency)
      Sidekiq::Queue.stubs(:new).with("high_priority").returns(queue)
    end
end
