class ApiRateLimiter
  # Rate limit tiers (requests per hour)
  RATE_LIMITS = {
    standard: 100,
    premium: 1000,
    enterprise: 10000
  }.freeze

  DEFAULT_TIER = :standard

  # Redis errors we handle: connection failures, timeouts, and server errors.
  # Redis::BaseError is the base for Redis::ConnectionError, Redis::TimeoutError, etc.
  # When any of these occur, we fail open (allow requests) so the API stays available.
  REDIS_ERRORS = [
    Redis::BaseError,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH
  ].freeze

  # Seconds to retain hourly buckets (2 hours for sliding window)
  BUCKET_RETENTION_SECONDS = 7200

  # Retry transient Redis failures up to this many times before failing open
  REDIS_RETRY_ATTEMPTS = 2

  # Delay in seconds between retries
  REDIS_RETRY_DELAY = 0.1

  def initialize(api_key)
    @api_key = api_key
    @redis = Redis.new
  end

  # Check if the API key has exceeded its rate limit
  def rate_limit_exceeded?
    current_count >= rate_limit
  end

  # Increment the request count for this API key.
  # No-op when Redis is unavailable (fail open).
  def increment_request_count!
    with_redis(fallback: nil) do |redis|
      key = redis_key
      current_time = Time.current.to_i
      window_start = (current_time / 3600) * 3600

      redis.multi do |transaction|
        transaction.hincrby(key, window_start.to_s, 1)
        transaction.expire(key, BUCKET_RETENTION_SECONDS)
      end

      cleanup_stale_buckets(redis, key)
      nil
    end
  end

  # Get current request count within the current hour.
  # Returns 0 when Redis is unavailable (fail open).
  def current_count
    with_redis(fallback: 0) do |redis|
      key = redis_key
      current_time = Time.current.to_i
      window_start = (current_time / 3600) * 3600

      count = redis.hget(key, window_start.to_s)
      count.to_i
    end
  end

  # Get the rate limit for this API key's tier
  def rate_limit
    tier = determine_tier
    RATE_LIMITS[tier]
  end

  # Calculate seconds until the rate limit resets
  def reset_time
    current_time = Time.current.to_i
    next_window = ((current_time / 3600) + 1) * 3600
    next_window - current_time
  end

  # Get detailed usage information.
  # When Redis is unavailable, current_count and remaining reflect fail-open state.
  def usage_info
    count = current_count
    limit = rate_limit
    {
      current_count: count,
      rate_limit: limit,
      remaining: [ limit - count, 0 ].max,
      reset_time: reset_time,
      tier: determine_tier,
      redis_available: redis_available?
    }
  end

  # Returns true if the last Redis operation succeeded.
  # Used by callers to know when rate limit data is authoritative.
  def redis_available?
    @redis_available != false
  end

  # Class method to get usage for an API key without incrementing
  def self.usage_for(api_key)
    limit(api_key).usage_info
  end

  def self.limit(api_key)
    if Rails.application.config.app_mode.self_hosted?
      # Use NoopApiRateLimiter for self-hosted mode
      # This means no rate limiting is applied
      NoopApiRateLimiter.new(api_key)
    else
      new(api_key)
    end
  end

  private

    def redis_key
      "api_rate_limit:#{@api_key.id}"
    end

    def determine_tier
      # For now, all API keys are standard tier
      # This can be extended later to support different tiers based on user subscription
      # or API key configuration
      DEFAULT_TIER
    end

    # Executes the block with Redis, with optional retries and a fallback on failure.
    # On Redis errors we log once, set @redis_available to false, and return fallback.
    # This ensures the API remains available when Redis is down or unreachable.
    def with_redis(fallback:)
      attempts = 0
      begin
        result = yield @redis
        @redis_available = true
        result
      rescue *REDIS_ERRORS => e
        attempts += 1
        if attempts <= REDIS_RETRY_ATTEMPTS
          sleep(REDIS_RETRY_DELAY)
          retry
        end

        @redis_available = false
        Rails.logger.warn(
          "ApiRateLimiter: Redis unavailable (#{e.class}: #{e.message}), failing open for api_key_id=#{@api_key&.id}"
        )
        fallback
      end
    end

    # Removes hourly buckets older than BUCKET_RETENTION_SECONDS to prevent unbounded hash growth.
    # Only runs when there is more than one bucket to avoid unnecessary Redis calls.
    def cleanup_stale_buckets(redis, key)
      return unless redis.is_a?(Redis)

      buckets = redis.hgetall(key)
      return if buckets.size <= 1

      cutoff = Time.current.to_i - BUCKET_RETENTION_SECONDS
      stale_keys = buckets.keys.select { |window_str| window_str.to_i < cutoff }
      redis.hdel(key, stale_keys) if stale_keys.any?
    rescue *REDIS_ERRORS
      # Best-effort cleanup; do not propagate so increment still succeeds
    end
end
