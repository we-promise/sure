require "test_helper"

class DailyWebUsageTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.utc(2026, 10, 2, 12)
    @user = users(:family_admin)
    @user.family.update!(timezone: "Etc/UTC")
    @previous_client = $posthog_feedback
    @previous_normal_client = $posthog
    events = @events = []
    @client = Object.new
    @client.define_singleton_method(:capture) { |event| events << event; true }
    $posthog_feedback = @client
    $posthog = mock("normal analytics client")
    $posthog.expects(:capture).never
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)
    Rails.env.stubs(:production?).returns(true)
    @config = Rails.configuration.x.posthog
    @config.stubs(:api_key).returns(nil)
    @config.stubs(:feedback_enabled).returns(true)
    sign_in @user
  end

  teardown do
    $posthog_feedback = @previous_client
    $posthog = @previous_normal_client
    travel_back
  end

  test "successful UI responses capture the first preview state once per user and day" do
    get settings_preferences_url, headers: { "REMOTE_ADDR" => "203.0.113.42" }
    assert_response :success
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    get settings_preferences_url

    assert_equal 1, @events.size
    event = @events.first
    assert_equal "web_ui_served_daily", event[:event]
    assert_equal({ preview_features_enabled: false, sure_version: Sure.version.to_s,
                   "$process_person_profile" => false, "$geoip_disable" => false,
                   "$ip" => "203.0.113.42" }, event[:properties])
    assert_match(/\A[0-9a-f]{64}\z/, event[:distinct_id])
    assert_not_includes event.to_json, @user.id
    assert_not_includes event.to_json, @user.email
  end

  test "GeoIP uses the client address Rails resolves through trusted proxies" do
    [
      { forwarded: "198.51.100.9, 203.0.113.42, 10.0.0.1", remote: "10.0.0.2", expected: "203.0.113.42" },
      { forwarded: "2001:db8::123, fd00::1", remote: "::1", expected: "2001:db8::123" }
    ].each do |example|
      @cache.clear
      get settings_preferences_url, headers: { "X-Forwarded-For" => example[:forwarded], "REMOTE_ADDR" => example[:remote] }

      assert_response :success
      assert_equal example[:expected], @events.last[:properties]["$ip"]
      assert_equal false, @events.last[:properties]["$geoip_disable"]
    end
  end

  test "another browser session for the same user shares the daily claim" do
    get settings_preferences_url
    browser = open_session
    browser.post sessions_url, params: { email: @user.email, password: user_password_test }
    browser.get settings_preferences_url

    assert_equal 1, @events.size
  end

  test "different users have independent daily claims and opaque identifiers" do
    get settings_preferences_url
    other = users(:family_member)
    other.update!(preferences: other.preferences.merge("preview_features_enabled" => true))
    sign_in other
    get settings_preferences_url

    assert_equal [ false, true ], @events.map { |event| event[:properties][:preview_features_enabled] }
    assert_not_equal @events.first[:distinct_id], @events.last[:distinct_id]
  end

  test "the next family-local calendar day records the new preference" do
    @user.family.update!(timezone: "America/Los_Angeles")
    travel_to Time.utc(2026, 10, 2, 6, 59)
    get settings_preferences_url
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    travel_to Time.utc(2026, 10, 2, 7)
    get settings_preferences_url

    assert_equal [ false, true ], @events.map { |event| event[:properties][:preview_features_enabled] }
    assert_not_equal @events.first[:distinct_id], @events.last[:distinct_id]
  end

  test "the daily identifier remains stable if the cache is cleared" do
    get settings_preferences_url
    @cache.clear
    get settings_preferences_url

    assert_equal 2, @events.size
    assert_equal @events.first[:distinct_id], @events.last[:distinct_id]
  end

  test "HEAD requests redirects errors and logged-out pages do not count" do
    head settings_preferences_url
    assert_response :success
    get insights_url
    assert_response :redirect
    get account_url(SecureRandom.uuid)
    assert_response :not_found
    delete session_url(Current.session)
    get new_session_url
    assert_response :success

    assert_empty @events
  end

  test "browser and Turbo prefetch or prerender requests do not count" do
    %w[Purpose Sec-Purpose X-Sec-Purpose].each do |header|
      get settings_preferences_url, headers: { header => "prefetch;prerender" }
      assert_response :success
    end

    assert_empty @events
  end

  test "authenticated API JSON and non-GET UI requests do not count" do
    api_key = @user.api_keys.create!(name: "Usage test", scopes: [ "read" ],
                             source: "web", display_key: "usage-test-#{SecureRandom.hex(8)}")
    get "/api/v1/accounts", headers: { "X-Api-Key" => api_key.display_key, "Accept" => "text/html" }
    assert_response :success
    assert_equal "application/json", response.media_type
    patch settings_preferences_url, params: { user: { preview_features_enabled: "1" } }
    assert_response :redirect

    assert_empty @events
  end

  test "AJAX and Turbo frame requests do not count as full UI responses" do
    get settings_preferences_url, headers: { "X-Requested-With" => "XMLHttpRequest" }
    assert_response :success
    get settings_preferences_url, headers: { "Turbo-Frame" => "drawer" }
    assert_response :success

    assert_empty @events
  end

  test "both hosting modes send only to shared feedback without operator analytics configuration" do
    %w[managed self_hosted].each do |mode|
      @cache.clear
      Rails.configuration.stubs(:app_mode).returns(mode.inquiry)
      get settings_preferences_url
      assert_response :success
    end

    assert_equal 2, @events.size
  end

  test "shared feedback opt-out or missing server client skips capture" do
    @config.stubs(:feedback_enabled).returns(false)
    get settings_preferences_url
    @config.stubs(:feedback_enabled).returns(true)
    $posthog_feedback = nil
    get settings_preferences_url

    assert_empty @events
  end

  test "configured operator analytics does not receive a duplicate" do
    @config.stubs(:api_key).returns("public-test-key")
    get settings_preferences_url

    assert_response :success
    assert_equal 1, @events.size
  end

  test "the existing environment gate requires explicit development opt-in" do
    Rails.env.stubs(:production?).returns(false)
    Rails.env.stubs(:development?).returns(true)
    @config.stubs(:development_enabled).returns(false)
    get settings_preferences_url
    assert_empty @events
    @config.stubs(:development_enabled).returns(true)
    get settings_preferences_url
    assert_equal 1, @events.size
  end

  test "null cache and unsuccessful cache claims skip capture" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::NullStore.new)
    get settings_preferences_url
    Rails.stubs(:cache).returns(@cache)
    @cache.stubs(:write).returns(false)
    get settings_preferences_url

    assert_response :success
    assert_empty @events
  end

  test "a cache claim failure cannot fail the UI response" do
    original_write = @cache.method(:write)
    @cache.define_singleton_method(:write) do |key, *args, **options|
      raise IOError, "cache unavailable" if key.is_a?(Array) && key.first == "daily-web-usage"
      original_write.call(key, *args, **options)
    end
    get settings_preferences_url

    assert_response :success
    assert_empty @events
  end

  test "SDK rejection or failure consumes one attempt without failing the UI" do
    [ false, StandardError.new("SDK unavailable") ].each do |result|
      @cache.clear
      calls = 0
      @client.define_singleton_method(:capture) do |_event|
        calls += 1
        raise result if result.is_a?(Exception)
        result
      end
      2.times do
        get settings_preferences_url
        assert_response :success
      end
      assert_equal 1, calls
    end
  end
end
