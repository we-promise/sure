require "test_helper"

class DailyInstallationUsageTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 10, 18, 23, 59)
    @previous_client = $posthog_feedback
    events = @events = []
    $posthog_feedback = Object.new
    $posthog_feedback.define_singleton_method(:capture) { |event| events << event }
    Rails.env.stubs(:production?).returns(true)
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(true)
    @claims = {}
    claims = @claims
    @redis = Object.new
    @redis.define_singleton_method(:call) do |command, key, value, nx, ex, ttl|
      raise "unexpected claim" unless [ command, value, nx, ex, ttl ] == [ "SET", "1", "NX", "EX", 172_800 ]
      next nil if claims.key?(key)
      claims[key] = true
      "OK"
    end
    @previous_redis = Sidekiq.method(:redis)
    redis = @redis
    Sidekiq.define_singleton_method(:redis) { |&block| block.call(redis) }
  end

  teardown do
    $posthog_feedback = @previous_client
    Sidekiq.define_singleton_method(:redis, @previous_redis)
    travel_back
  end

  test "events have independent install claims and minimal daily identities" do
    3.times { DailyInstallationUsage::EVENTS.each { |event| DailyInstallationUsage.capture(event) } }
    assert_equal DailyInstallationUsage::EVENTS, @events.map { |event| event[:event] }
    assert_equal 1, @events.pluck(:distinct_id).uniq.size
    assert_match(/\A[0-9a-f]{64}\z/, @events.first[:distinct_id])
    assert_equal({ sure_version: Sure.version.to_s, "$process_person_profile" => false,
                   "$geoip_disable" => true }, @events.first[:properties])
    assert_equal 2, @claims.size
  end

  test "UTC rollover is independent of thread or family timezone" do
    Time.use_zone("Pacific/Auckland") { DailyInstallationUsage.capture("job_served_daily") }
    Time.use_zone("America/Los_Angeles") { DailyInstallationUsage.capture("job_served_daily") }
    assert_equal 1, @events.size
    travel_to Time.utc(2026, 10, 19)
    DailyInstallationUsage.capture("job_served_daily")
    assert_equal 2, @events.size
    assert_not_equal @events.first[:distinct_id], @events.last[:distinct_id]
  end

  test "feedback opt out does not claim a day and later opt in can capture" do
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(false)
    DailyInstallationUsage.capture("job_served_daily")
    assert_empty @claims
    assert_empty @events
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(true)
    DailyInstallationUsage.capture("job_served_daily")
    assert_equal 1, @events.size
  end

  test "tests and development without explicit opt in do not claim" do
    Rails.env.stubs(:production?).returns(false)
    Rails.env.stubs(:development?).returns(false)
    DailyInstallationUsage.capture("job_served_daily")
    Rails.env.stubs(:development?).returns(true)
    Rails.configuration.x.posthog.stubs(:development_enabled).returns(false)
    DailyInstallationUsage.capture("job_served_daily")
    assert_empty @claims
    Rails.configuration.x.posthog.stubs(:development_enabled).returns(true)
    DailyInstallationUsage.capture("job_served_daily")
    assert_equal 1, @events.size
  end

  test "missing collector and unrecognized events do not claim" do
    DailyInstallationUsage.capture("private_job_name")
    $posthog_feedback = nil
    DailyInstallationUsage.capture("job_served_daily")
    assert_empty @claims
  end

  test "Redis failures do not escape or capture" do
    @redis.stubs(:call).raises(IOError)
    DailyInstallationUsage.capture("job_served_daily")
    assert_empty @events
  end

  test "collector failures preserve the claim rather than retry delivery" do
    $posthog_feedback.expects(:capture).once.raises(IOError)
    2.times { DailyInstallationUsage.capture("job_served_daily") }
    assert_equal 1, @claims.size
  end
end
