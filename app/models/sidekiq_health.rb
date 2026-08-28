# Snapshot of Sidekiq's current operational state, used to surface a
# user-facing "data unavailable" nudge when background jobs aren't being
# processed. This is the symptom side of the most common Docker Compose
# misconfiguration: the worker container isn't running, so sync jobs,
# balance recalculations, and net-worth updates silently never execute
# and the UI shows zeros without explaining why (#1481).
#
# Healthy = Redis reachable AND at least one worker heartbeat is fresh
# AND the oldest enqueued job hasn't been waiting longer than the
# configured latency budget. Anything else flips `healthy?` to false and
# `reason` gives the most-specific failure for display / logging.
#
# Reuse via `SidekiqHealth.current` (or `ApplicationController#current_sidekiq_health`)
# rather than `.new` so the result is shared across a request and cached
# for `CACHE_TTL` across requests — `.new` always hits Redis. All Sidekiq
# calls are eager-loaded in `initialize` and wrapped in a defensive
# rescue — a degraded Redis must never crash a page render.
class SidekiqHealth
  # A worker is considered alive if it published a heartbeat within this
  # window. Sidekiq's default heartbeat interval is 5s, so 2 minutes is
  # conservative — covers a temporarily-paused worker, deploy restart, or
  # transient Redis blip without flapping the banner. Operators on
  # under-resourced self-hosted boxes can raise it via
  # `SIDEKIQ_HEALTH_HEARTBEAT_TIMEOUT` (seconds) if heartbeats legitimately
  # arrive slower than this on their hardware.
  PROCESS_HEARTBEAT_TIMEOUT = (ENV["SIDEKIQ_HEALTH_HEARTBEAT_TIMEOUT"].presence&.to_i&.then { |s| s.seconds } || 2.minutes)

  # Oldest-enqueued-job age that we treat as "backed up". Tuned to the
  # default queue config in `config/sidekiq.yml` (concurrency: 3): a
  # healthy queue empties well inside this window even under bursty
  # sync load. Self-hosted deployments running a single-threaded worker
  # or large sync backlogs can raise it via `SIDEKIQ_HEALTH_LATENCY_THRESHOLD`
  # (seconds) to avoid a constant false-positive banner.
  LATENCY_THRESHOLD = (ENV["SIDEKIQ_HEALTH_LATENCY_THRESHOLD"].presence&.to_i&.then { |s| s.seconds } || 5.minutes)

  # How long a cached health snapshot is reused before re-querying Redis.
  # A bad worker is visible within `CACHE_TTL` of the failure — short
  # enough to feel live, long enough that authenticated page loads don't
  # round-trip Redis on every render. Override with `SIDEKIQ_HEALTH_CACHE_TTL`
  # (seconds) if needed.
  CACHE_TTL = (ENV["SIDEKIQ_HEALTH_CACHE_TTL"].presence&.to_i&.then { |s| s.seconds } || 60.seconds)

  CACHE_KEY = "sidekiq_health/v1"

  REASONS = %i[redis_unreachable no_worker_processes stale_heartbeat queue_backed_up].freeze

  attr_reader :processes_count, :last_heartbeat_at, :max_queue_latency, :queue_breakdown,
              :enqueued_count, :failed_count, :processed_count, :retry_count

  class << self
    # Convenience for view helpers / banners that just need the boolean.
    def healthy?
      current.healthy?
    end

    # Cached entry point. Re-uses a snapshot for up to `CACHE_TTL` so
    # the global banner check doesn't add a Redis round-trip per page
    # load. Cache misses still pay the full Sidekiq query, but only once
    # per TTL window across the whole process.
    def current
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { new }
    end

    # Forces the next `current` call to re-query Redis. Useful from the
    # admin page so an operator who just restarted the worker sees the
    # new state immediately.
    def expire_cache!
      Rails.cache.delete(CACHE_KEY)
    end
  end

  def initialize
    @processes_count = 0
    @last_heartbeat_at = nil
    @max_queue_latency = 0.0
    @queue_breakdown = []
    @enqueued_count = 0
    @failed_count = 0
    @processed_count = 0
    @retry_count = 0
    @load_failure = nil

    load_state!
  end

  def healthy?
    reason.nil?
  end

  # Most-specific failure first; nil when healthy. Stable symbol so the
  # banner i18n keys can switch on it.
  def reason
    return :redis_unreachable if @load_failure
    return :no_worker_processes if processes_count.zero?
    # A registered process with no published heartbeat is just as
    # suspect as one whose last heartbeat is stale — either way Sidekiq
    # isn't telling us a worker is alive.
    return :stale_heartbeat if last_heartbeat_at.nil? || last_heartbeat_at < PROCESS_HEARTBEAT_TIMEOUT.ago
    return :queue_backed_up if max_queue_latency > LATENCY_THRESHOLD
    nil
  end

  private
    # Eagerly fetches every Sidekiq stat we need in one pass so we can
    # catch Redis failures at the boundary instead of relying on lazy
    # Sidekiq client calls inside view code. Any failure is recorded as
    # `:redis_unreachable` — we never let a degraded broker crash a page.
    def load_state!
      process_set = Sidekiq::ProcessSet.new
      @processes_count = process_set.size

      beats = process_set.map { |p| p["beat"] }.compact
      @last_heartbeat_at = beats.present? ? Time.at(beats.max) : nil

      queues = Sidekiq::Queue.all
      latencies = queues.map { |q| q.latency.to_f }
      @max_queue_latency = latencies.max.to_f
      @queue_breakdown = queues.sort_by(&:name).map { |q| [ q.name, q.size, q.latency.to_f ] }

      stats = Sidekiq::Stats.new
      @enqueued_count = stats.enqueued.to_i
      @failed_count = stats.failed.to_i
      @processed_count = stats.processed.to_i
      @retry_count = stats.retry_size.to_i
    rescue Redis::BaseError, RedisClient::Error => e
      @load_failure = e
      Rails.logger.warn("[SidekiqHealth] Redis unreachable: #{e.class}: #{e.message}")
    rescue StandardError => e
      # Defensive fallback — Sidekiq internals can raise unexpected
      # errors (e.g., misconfigured client, version mismatch) and the
      # layout still has to render. Treat any non-Redis error as a
      # `:redis_unreachable` signal so the banner shows and the admin
      # gets pointed at the system-health page to investigate.
      @load_failure = e
      Rails.logger.warn("[SidekiqHealth] Unexpected error: #{e.class}: #{e.message}")
    end
end
