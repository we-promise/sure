require "sidekiq/api"

# Reads Sidekiq's runtime state (live worker processes + queue latency) directly
# from Redis in the *web* process, so a down or stuck worker can be detected even
# when the worker itself is the thing that's broken (a worker-side healthcheck
# can't report that it's dead).
#
# Fails open: if Sidekiq/Redis is unreachable we assume healthy rather than block
# or alarm the UI on an unrelated infrastructure blip.
class BackgroundJobHealth
  # Syncs and imports run here; chat runs on the interactive lane's queue.
  CRITICAL_QUEUE = "high_priority".freeze
  CHAT_QUEUE = Ai::Routes.queue_for(:chat)
  AI_QUEUES = Ai::Routes.ai_queues
  # A worker whose ai capsule has one thread for the prompt and background
  # queues adds this label to its Sidekiq process at startup
  # (config/initializers/sidekiq.rb), so web processes read the worker's
  # capsule instead of their own RAILS_AI_MAX_THREADS.
  ONE_AI_THREAD_LABEL = "one-ai-thread".freeze
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

    # Only when a single worker process polls the AI queues: with several, a
    # chat can reach a model while another runs background AI jobs.
    def one_ai_thread?
      ai_processes = Sidekiq::ProcessSet.new(false).select { |process| process.queues.intersect?(AI_QUEUES) }
      ai_processes.one? && ai_processes.first.labels.include?(ONE_AI_THREAD_LABEL)
    rescue => e
      Rails.logger.warn("BackgroundJobHealth AI thread check failed: #{e.class}: #{e.message}")
      false
    end

    # One thread runs every prompt and background job, so a chat's model call
    # can wait behind it on a local model (ChatReservation holds them back).
    def one_ai_thread_worker?(config)
      capsules = config.capsules.values.select { |capsule| capsule.queues.intersect?(ChatReservation::HELD_QUEUES) }
      lanes = Ai::Routes::QUEUES.values_at(:prompt, :background)
      capsules.one? && capsules.first.concurrency == 1 && (lanes - capsules.first.queues).empty?
    end

    # With one AI thread, a chat sent now waits for any running AI job.
    def ai_busy?
      one_ai_thread? && ai_job_running?
    end

    def ai_job_running?(queues: AI_QUEUES)
      Sidekiq::WorkSet.new.any? { |_process, _thread, work| queues.include?(work.queue) }
    rescue => e
      Rails.logger.warn("BackgroundJobHealth busy check failed: #{e.class}: #{e.message}")
      false
    end

    # The gate of an AI endpoint's local model host, as its worker last published it
    # (Ai::Gate::State), or nil: a cloud endpoint, or a host no worker's gate is in use for.
    def model_gate(endpoint)
      Ai::Gate::State.read(Ai::Sequencer.host_key(endpoint)) if endpoint&.local?
    rescue => e
      Rails.logger.warn("BackgroundJobHealth model gate check failed: #{e.class}: #{e.message}")
      nil
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
