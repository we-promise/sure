require "sidekiq/api"

# Reads Sidekiq's runtime state (live worker processes + queue latency) directly
# from Redis in the *web* process, so a down or stuck worker can be detected even
# when the worker itself is the thing that's broken (a worker-side healthcheck
# can't report that it's dead).
#
# Fails open: if Sidekiq/Redis is unreachable we assume healthy rather than block
# or alarm the UI on an unrelated infrastructure blip.
class BackgroundJobHealth
  # The queue chat (AssistantResponseJob), syncs and imports run on. If nothing
  # is polling it, user-facing background work silently never runs.
  CRITICAL_QUEUE = "high_priority".freeze
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

    def summary
      h = current
      "workers=#{h[:workers].inspect} polls_#{CRITICAL_QUEUE}=#{h[:polls_critical_queue].inspect} latency=#{h[:latency].inspect}s"
    end

    private
      def compute
        processes = Sidekiq::ProcessSet.new
        workers = processes.size
        polled_queues = processes.flat_map { |p| Array(p["queues"]) }.uniq
        polls_critical = polled_queues.include?(CRITICAL_QUEUE)
        latency = Sidekiq::Queue.new(CRITICAL_QUEUE).latency

        {
          healthy: workers.positive? && polls_critical && latency < LATENCY_WARN_SECONDS,
          workers: workers,
          polls_critical_queue: polls_critical,
          latency: latency.round(1),
          checked_at: Time.current
        }
      end

      def fail_open
        { healthy: true, workers: nil, polls_critical_queue: nil, latency: nil, checked_at: Time.current, error: true }
      end
  end
end
