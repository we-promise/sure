require "test_helper"

class OnboardingUsageTest < ActiveSupport::TestCase
  setup do
    @previous_client = $posthog_feedback
    @events = []
    events = @events
    $posthog_feedback = Object.new
    $posthog_feedback.define_singleton_method(:capture) { |event| events << event }
    Rails.env.stubs(:production?).returns(true)
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(true)
  end

  teardown do
    $posthog_feedback = @previous_client
  end

  test "captures only allowed intent and anonymous event properties" do
    Usage.capture_onboarding_ai_intent(family_id: "private-family", mode: "external")
    event = @events.fetch(0)
    assert_equal "initial_family_ai_mode_selected", event[:event]
    key = Rails.application.key_generator.generate_key("initial-family-onboarding-ai-intent")
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", key, "private-family"), event[:distinct_id]
    assert_equal({ ai_mode: "external", sure_version: Sure.version.to_s,
                   "$process_person_profile" => false, "$geoip_disable" => true }, event[:properties])
    Usage.capture_onboarding_ai_intent(family_id: "private-family", mode: "invalid")
    assert_equal 1, @events.size
  end

  test "operator opt out and missing collector suppress capture" do
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(false)
    Usage.capture_onboarding_ai_intent(family_id: "family", mode: "none")
    assert_empty @events
    Rails.configuration.x.posthog.stubs(:feedback_enabled).returns(true)
    $posthog_feedback = nil
    assert_nothing_raised { Usage.capture_onboarding_ai_intent(family_id: "family", mode: "none") }
  end

  test "test and development environments require explicit development opt in" do
    Rails.env.stubs(:production?).returns(false)
    Rails.env.stubs(:development?).returns(false)
    Usage.capture_onboarding_ai_intent(family_id: "family", mode: "none")
    Rails.env.stubs(:development?).returns(true)
    Rails.configuration.x.posthog.stubs(:development_enabled).returns(false)
    Usage.capture_onboarding_ai_intent(family_id: "family", mode: "none")
    assert_empty @events
    Rails.configuration.x.posthog.stubs(:development_enabled).returns(true)
    Usage.capture_onboarding_ai_intent(family_id: "family", mode: "none")
    assert_equal 1, @events.size
  end

  test "collector failures do not block onboarding" do
    $posthog_feedback.expects(:capture).raises(StandardError, "unavailable")
    assert_nothing_raised { Usage.capture_onboarding_ai_intent(family_id: "family", mode: "builtin") }
  end
end
