require "test_helper"

# Opt in against a disposable Redis configured through REDIS_URL. No collector
# requests are sent: the fake collector records accepted captures in Redis.
class DailyUsageRedisTest < ActiveSupport::TestCase
  test "independent worker processes share atomic claims for both events" do
    skip "Set DAILY_USAGE_REDIS_TESTS=1 with disposable REDIS_URL" unless ENV["DAILY_USAGE_REDIS_TESTS"] == "1"
    skip "Requires fork" unless Process.respond_to?(:fork)

    previous_client = $posthog_feedback
    travel_to Time.utc(2031, 1, 1)
    Rails.env.stubs(:production?).returns(true)
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(true)
    secret = SecureRandom.hex(32)
    Rails.application.key_generator.stubs(:generate_key).with("daily-installation-usage").returns(secret)
    results_key = "daily-usage-test:#{SecureRandom.hex(16)}"
    daily_id = OpenSSL::HMAC.hexdigest("SHA256", secret, "2031-01-01")
    expected_events = %w[ai_assistant_served_daily job_served_daily]
    claim_keys = expected_events.map { |event| "daily-installation-usage:#{event}:#{daily_id}" }
    $posthog_feedback = Object.new
    $posthog_feedback.define_singleton_method(:capture) do |event|
      Sidekiq.redis { |redis| redis.call("RPUSH", results_key, event.to_json) }
    end

    reader, writer = IO.pipe
    pids = 8.times.map do
      fork do
        writer.close
        reader.read(1)
        10.times do
          DailyJobUsageTracking.new.call(nil, {}, nil) { true }
          DailyUsage.capture("ai_assistant_served_daily")
        end
        exit! 0
      rescue StandardError
        exit! 1
      end
    end
    reader.close
    writer.write("x" * pids.size)
    writer.close
    pids.each { |pid| assert Process.wait2(pid).last.success? }
    events = Sidekiq.redis { |redis| redis.call("LRANGE", results_key, 0, -1) }.map { |json| JSON.parse(json) }
    assert_equal expected_events.sort, events.map { |event| event["event"] }.sort
    assert_equal [ daily_id ], events.map { |event| event["distinct_id"] }.uniq
    travel_to Time.utc(2031, 1, 2)
    next_id = OpenSSL::HMAC.hexdigest("SHA256", secret, "2031-01-02")
    claim_keys.concat(expected_events.map { |event| "daily-installation-usage:#{event}:#{next_id}" })
    2.times { expected_events.each { |event| DailyUsage.capture(event) } }
    events = Sidekiq.redis { |redis| redis.call("LRANGE", results_key, 0, -1) }.map { |json| JSON.parse(json) }
    assert_equal 4, events.size
    assert_equal [ daily_id, next_id ].sort, events.map { |event| event["distinct_id"] }.uniq.sort
    claim_keys.each do |key|
      ttl = Sidekiq.redis { |redis| redis.call("TTL", key) }
      assert_operator ttl, :>, 86_400
      assert_operator ttl, :<=, 172_800
    end
  ensure
    $posthog_feedback = previous_client if defined?(previous_client)
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    Sidekiq.redis { |redis| redis.call("DEL", results_key, *claim_keys) } if results_key && claim_keys
    travel_back
  end
end
