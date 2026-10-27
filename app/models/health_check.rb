require "sidekiq/api"

# Dependency checks behind the public GET /health endpoint polled by an external
# uptime monitor. The response is public, so every reason below is a literal
# written here; the only runtime values allowed in one are numbers this class
# computes. Anything a dependency raises is logged and reported generically.
class HealthCheck
  TIMEOUT = 3.seconds

  # The most frequent cron entries run every 15 minutes, so a scheduler that
  # hasn't enqueued anything for this long has stopped.
  MAX_SCHEDULER_SILENCE = 2.hours

  # Cron jobs land on `scheduled`, syncs and imports on `high_priority`. A job
  # left waiting this long means no worker is taking from that queue.
  WATCHED_QUEUES = %w[scheduled high_priority].freeze
  MAX_QUEUE_LATENCY = 1.hour

  CHECKS = { db: :check_db, redis: :check_redis, worker: :check_worker }.freeze

  # Its message is published as-is, so raise it only with a literal reason.
  class Failure < StandardError; end

  def self.errors
    new.errors
  end

  def initialize(timeout: TIMEOUT)
    @timeout = timeout
  end

  # Runs every check in parallel and returns "<component>: <reason>" strings.
  # A check still running at the deadline is reported as a timeout and left to
  # finish in the background.
  def errors
    threads = CHECKS.to_h { |name, check| [ name, Thread.new { run(name, check) } ] }
    deadline = monotonic_now + @timeout

    threads.filter_map do |name, thread|
      if thread.join([ deadline - monotonic_now, 0 ].max)
        thread.value
      else
        "#{name}: timeout after #{(@timeout * 1000).round}ms"
      end
    end
  end

  private
    def run(name, check)
      send(check)
      nil
    rescue Failure => e
      "#{name}: #{e.message}"
    rescue => e
      Rails.logger.error("[HealthCheck] #{name} check failed: #{e.class}: #{e.message}")
      "#{name}: check failed"
    end

    def check_db
      ActiveRecord::Base.connection_pool.with_connection { |connection| connection.select_value("SELECT 1") }
    end

    def check_redis
      raise Failure, "unexpected PING reply" unless Sidekiq.redis { |redis| redis.call("PING") } == "PONG"
    end

    # A live process alone doesn't prove jobs run: the cron poller must still be
    # enqueuing, and workers must be draining what it enqueues.
    def check_worker
      # `false` skips pruning dead processes, which would write to Redis.
      raise Failure, "no worker process running" if Sidekiq::ProcessSet.new(false).none?

      last_enqueued = Sidekiq::Cron::Job.all.filter_map(&:last_enqueue_time).max
      raise Failure, "no scheduled job enqueued yet" if last_enqueued.nil?

      silence = Time.current - last_enqueued
      raise Failure, "no scheduled job enqueued in #{(silence / 1.hour).floor}h" if silence > MAX_SCHEDULER_SILENCE

      latency = WATCHED_QUEUES.map { |queue| Sidekiq::Queue.new(queue).latency }.max
      raise Failure, "jobs waiting #{(latency / 60).floor}m unprocessed" if latency > MAX_QUEUE_LATENCY
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
