require "test_helper"

class UsageTest < ActiveSupport::TestCase
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
    3.times do
      Usage.capture("ai_assistant_served_daily")
      Usage.capture("job_served_daily")
      Usage.capture("mcp_call_served_daily")
    end
    assert_equal %w[ai_assistant_served_daily job_served_daily mcp_call_served_daily], @events.pluck(:event)
    assert_equal 1, @events.pluck(:distinct_id).uniq.size
    assert_match(/\A[0-9a-f]{64}\z/, @events.first[:distinct_id])
    assert_equal({ sure_version: Sure.version.to_s, "$process_person_profile" => false,
                   "$geoip_disable" => true }, @events.first[:properties])
    assert_equal 3, @claims.size
  end

  test "web and installation events preserve independent claims identities and properties" do
    user = stub(id: "web-user", preview_features_enabled?: true)
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    date = Date.new(2026, 10, 18)

    2.times do
      Usage.capture("web_ui_served_daily", user: user, date: date, ip: "203.0.113.42")
      Usage.capture("ai_assistant_served_daily")
      Usage.capture("job_served_daily")
      Usage.capture("mcp_call_served_daily")
    end

    assert_equal %w[web_ui_served_daily ai_assistant_served_daily job_served_daily mcp_call_served_daily], @events.pluck(:event)
    web, assistant, job, mcp = @events
    web_key = Rails.application.key_generator.generate_key("daily-web-usage")
    installation_key = Rails.application.key_generator.generate_key("daily-installation-usage")
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", web_key, "#{user.id}:#{date.iso8601}"), web[:distinct_id]
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", installation_key, date.iso8601), assistant[:distinct_id]
    assert_equal assistant[:distinct_id], job[:distinct_id]
    assert_equal assistant[:distinct_id], mcp[:distinct_id]
    assert_not_equal web[:distinct_id], assistant[:distinct_id]
    assert_equal({ sure_version: Sure.version.to_s, preview_features_enabled: user.preview_features_enabled?,
                   "$process_person_profile" => false, "$geoip_disable" => false,
                   "$ip" => "203.0.113.42" }, web[:properties])
    [ assistant, job, mcp ].each do |event|
      assert_equal({ sure_version: Sure.version.to_s, "$process_person_profile" => false,
                     "$geoip_disable" => true }, event[:properties])
    end
    assert_equal true, cache.read([ "daily-web-usage", web[:distinct_id] ])
    assert_equal 3, @claims.size
  end

  test "web events require a user and family-local date" do
    Usage.capture("web_ui_served_daily")
    Usage.capture("web_ui_served_daily", user: stub(id: "web-user"))
    Usage.capture("web_ui_served_daily", date: Date.current)

    assert_empty @claims
    assert_empty @events
  end

  test "a null Rails cache disables web capture while installation events stay enabled" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::NullStore.new)

    assert_not Usage.enabled?("web_ui_served_daily")
    assert Usage.enabled?("ai_assistant_served_daily")
    assert Usage.enabled?("job_served_daily")
    assert Usage.enabled?("mcp_call_served_daily")
  end

  test "UTC rollover is independent of thread or family timezone" do
    events = %w[ai_assistant_served_daily job_served_daily mcp_call_served_daily]
    Time.use_zone("Pacific/Auckland") { events.each { |event| Usage.capture(event) } }
    Time.use_zone("America/Los_Angeles") { events.each { |event| Usage.capture(event) } }
    assert_equal 3, @events.size
    travel_to Time.utc(2026, 10, 19)
    events.each { |event| Usage.capture(event) }
    assert_equal 6, @events.size
    assert_not_equal @events.first[:distinct_id], @events.last[:distinct_id]
  end

  test "feedback opt out does not claim a day and later opt in can capture" do
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(false)
    Usage.capture("job_served_daily")
    assert_empty @claims
    assert_empty @events
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(true)
    Usage.capture("job_served_daily")
    assert_equal 1, @events.size
  end

  test "tests and development without explicit opt in do not claim" do
    Rails.env.stubs(:production?).returns(false)
    Rails.env.stubs(:development?).returns(false)
    Usage.capture("job_served_daily")
    Rails.env.stubs(:development?).returns(true)
    Rails.configuration.x.posthog.stubs(:development_enabled).returns(false)
    Usage.capture("job_served_daily")
    assert_empty @claims
    Rails.configuration.x.posthog.stubs(:development_enabled).returns(true)
    Usage.capture("job_served_daily")
    assert_equal 1, @events.size
  end

  test "missing collector and unrecognized events do not claim" do
    Usage.capture("private_job_name")
    $posthog_feedback = nil
    Usage.capture("job_served_daily")
    assert_empty @claims
  end

  test "Redis failures do not escape or capture" do
    @redis.stubs(:call).raises(IOError)
    Usage.capture("job_served_daily")
    assert_empty @events
  end

  test "collector failures preserve the claim rather than retry delivery" do
    $posthog_feedback.expects(:capture).once.raises(IOError)
    2.times { Usage.capture("job_served_daily") }
    assert_equal 1, @claims.size
  end
end
