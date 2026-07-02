module ApiRateLimitTestHelper
  # Seeds the ApiRateLimiter Redis counter for the current hourly window so
  # tests can start at/near the limit without issuing hundreds of real
  # requests through the full stack.
  def seed_api_rate_limit(api_key, count)
    window_start = (Time.current.to_i / 3600) * 3600
    Redis.new.hset("api_rate_limit:#{api_key.id}", window_start.to_s, count)
  end
end
