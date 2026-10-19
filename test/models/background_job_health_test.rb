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

  test "a chat waiting behind another AI job is busy, not unhealthy" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "ai_high_priority" ] } ], latency: 0.0, ai_high: 45.0)

    assert BackgroundJobHealth.healthy?
    assert BackgroundJobHealth.ai_busy?
  end

  test "with one AI thread, an ai_low_priority backlog is busy" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "ai_high_priority" ] } ], latency: 0.0, ai_low: 45.0)

    with_env_overrides("RAILS_AI_MAX_THREADS" => nil) { assert BackgroundJobHealth.ai_busy? }
  end

  test "with several AI threads, an ai_low_priority backlog isn't busy" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "ai_high_priority" ] } ], latency: 0.0, ai_low: 45.0)

    with_env_overrides("RAILS_AI_MAX_THREADS" => "2") { assert_not BackgroundJobHealth.ai_busy? }
  end

  test "fails open when Sidekiq/Redis is unreachable" do
    Sidekiq::ProcessSet.stubs(:new).raises(StandardError.new("no redis"))

    assert BackgroundJobHealth.healthy?
    assert BackgroundJobHealth.snapshot[:error]
  end

  private
    def stub_sidekiq(processes:, latency:, ai_high: 0.0, ai_low: 0.0)
      process_set = mock("ProcessSet")
      process_set.stubs(:size).returns(processes.size)
      process_set.stubs(:flat_map).returns(processes.flat_map { |p| p["queues"] })
      Sidekiq::ProcessSet.stubs(:new).returns(process_set)

      { "high_priority" => latency, "ai_high_priority" => ai_high, "ai_low_priority" => ai_low }.each do |name, wait|
        Sidekiq::Queue.stubs(:new).with(name).returns(stub(latency: wait))
      end
    end
end
