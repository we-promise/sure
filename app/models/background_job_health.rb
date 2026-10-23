require "sidekiq/api"

# Reads Sidekiq's runtime state (live worker processes + queue latency) directly
# from Redis in the *web* process, so a down or stuck worker can be detected even
# when the worker itself is the thing that's broken (a worker-side healthcheck
# can't report that it's dead).
#
# Fails open: if Sidekiq/Redis is unreachable we assume healthy rather than block
# or alarm the UI on an unrelated infrastructure blip.
class BackgroundJobHealth
  # Syncs and imports run here; chat runs on ai_high_priority.
  CRITICAL_QUEUE = "high_priority".freeze
  CHAT_QUEUE = "ai_high_priority".freeze
  AI_QUEUES = [ CHAT_QUEUE, "ai_low_priority" ].freeze
  LATENCY_WARN_SECONDS = 60

  CACHE_KEY = "background_job_health".freeze
  CACHE_TTL = 15.seconds

  class << self
    def current
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { compute }
    rescue => e
      Rails.logger.warn("BackgroundJobHealth check failed: #{e.class}: #{e.message}")
      fail_open
    end

    def healthy?
      current[:healthy]
    end

    def snapshot
      current
    end

    def one_ai_thread?
      ENV.fetch("RAILS_AI_MAX_THREADS", 1).to_i == 1
    end

    # With one AI thread, a chat sent now waits for any running AI job.
    def ai_busy?(queues: AI_QUEUES)
      one_ai_thread? && Sidekiq::WorkSet.new.any? { |_process, _thread, work| queues.include?(work.queue) }
    rescue => e
      Rails.logger.warn("BackgroundJobHealth busy check failed: #{e.class}: #{e.message}")
      false
    end

    def summary
      h = current
      "workers=#{h[:workers].inspect} polls_#{CRITICAL_QUEUE}=#{h[:polls_critical_queue].inspect} polls_#{CHAT_QUEUE}=#{h[:polls_chat_queue].inspect} latency=#{h[:latency].inspect}s"
    end

    private
      def compute
        processes = Sidekiq::ProcessSet.new
        workers = processes.size
        polled_queues = processes.flat_map { |p| Array(p["queues"]) }.uniq
        polls_critical = polled_queues.include?(CRITICAL_QUEUE)
        polls_chat = polled_queues.include?(CHAT_QUEUE)
        latency = Sidekiq::Queue.new(CRITICAL_QUEUE).latency

        {
          healthy: workers.positive? && polls_critical && polls_chat && latency < LATENCY_WARN_SECONDS,
          workers: workers,
          polls_critical_queue: polls_critical,
          polls_chat_queue: polls_chat,
          latency: latency.round(1),
          checked_at: Time.current
        }
      end

      def fail_open
        { healthy: true, workers: nil, polls_critical_queue: nil, polls_chat_queue: nil, latency: nil, checked_at: Time.current, error: true }
      end
  end
end
