require "test_helper"

class BackgroundJobHealthTest < ActiveSupport::TestCase
  setup { Rails.cache.delete(BackgroundJobHealth::CACHE_KEY) }
  teardown { Rails.cache.delete(BackgroundJobHealth::CACHE_KEY) }

  test "healthy when a worker polls the critical queue with low latency" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "default", "ai_interactive" ] } ], latency: 1.0)

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
    stub_sidekiq(processes: [ { "queues" => [ "high_priority", "ai_interactive" ] } ], latency: 9_999)

    assert_not BackgroundJobHealth.healthy?
  end

  test "unhealthy when no worker polls the chat queue" do
    stub_sidekiq(processes: [ { "queues" => [ "high_priority" ] } ], latency: 0.0)

    assert_not BackgroundJobHealth.healthy?
  end

  test "a reply is in line while its job is queued and a worker polls the chat queue" do
    reply, other = messages(:chat1_assistant_response), AssistantMessage.new(id: SecureRandom.uuid)
    job = stub(args: [ { "arguments" => [ { "_aj_globalid" => other.to_global_id.to_s }, { "_aj_globalid" => reply.to_global_id.to_s } ] } ])
    Sidekiq::Queue.stubs(:new).with(BackgroundJobHealth::CHAT_QUEUE).returns([ stub(args: []), job ])

    BackgroundJobHealth.stubs(:current).returns(polls_chat_queue: true)
    assert BackgroundJobHealth.reply_queued?(reply)
    assert_not BackgroundJobHealth.reply_queued?(AssistantMessage.new(id: SecureRandom.uuid))

    BackgroundJobHealth.stubs(:current).returns(polls_chat_queue: false)
    assert_not BackgroundJobHealth.reply_queued?(reply), "no worker would run it"
    BackgroundJobHealth.stubs(:current).returns(polls_chat_queue: nil)
    assert_not BackgroundJobHealth.reply_queued?(reply), "Sidekiq can't be read"
  end

  test "fails open when Sidekiq/Redis is unreachable" do
    Sidekiq::ProcessSet.stubs(:new).raises(StandardError.new("no redis"))

    assert BackgroundJobHealth.healthy?
    assert BackgroundJobHealth.snapshot[:error]
    assert_not BackgroundJobHealth.reply_queued?(AssistantMessage.new(id: SecureRandom.uuid))
  end

  private
    def stub_sidekiq(processes:, latency:)
      process_set = mock("ProcessSet")
      process_set.stubs(:size).returns(processes.size)
      process_set.stubs(:flat_map).returns(processes.flat_map { |p| p["queues"] })
      Sidekiq::ProcessSet.stubs(:new).returns(process_set)

      Sidekiq::Queue.stubs(:new).with("high_priority").returns(stub(latency: latency))
    end
end
