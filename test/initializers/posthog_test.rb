require "test_helper"

class PosthogTest < ActiveSupport::TestCase
  setup do
    @previous_config = Rails.configuration.x.posthog
    @previous_normal_client = $posthog
    @previous_feedback_client = $posthog_feedback
    $posthog = $posthog_feedback = nil
    Rails.env.stubs(:production?).returns(false)
    Rails.env.stubs(:development?).returns(false)
  end

  teardown do
    Rails.configuration.x.posthog = @previous_config
    $posthog = @previous_normal_client
    $posthog_feedback = @previous_feedback_client
  end

  test "production feedback uses the bundled project independently of operator analytics" do
    Rails.env.stubs(:production?).returns(true)
    normal_client = mock("normal analytics")
    feedback_client = mock("shared feedback")
    PostHog::Client.expects(:new).with(has_entries(api_key: "operator-test-key", host: "https://analytics.example.test")).returns(normal_client)
    PostHog::Client.expects(:new).with(has_entries(@previous_config.self_hosted_feedback_project)).returns(feedback_client)

    load_initializer(POSTHOG_KEY: "operator-test-key", POSTHOG_HOST: "https://analytics.example.test")

    assert_same normal_client, $posthog
    assert_same feedback_client, $posthog_feedback
  end

  test "feedback opt-out does not initialize the shared client" do
    Rails.env.stubs(:production?).returns(true)
    PostHog::Client.expects(:new).never

    load_initializer(POSTHOG_FEEDBACK_ENABLED: "false")

    assert_nil $posthog_feedback
  end

  test "development requires explicit opt-in" do
    Rails.env.stubs(:development?).returns(true)
    PostHog::Client.expects(:new).never

    load_initializer

    assert_nil $posthog_feedback
  end

  test "development opt-in uses the shared project without operator configuration" do
    Rails.env.stubs(:development?).returns(true)
    feedback_client = mock("shared feedback")
    PostHog::Client.expects(:new).with(has_entries(@previous_config.self_hosted_feedback_project)).returns(feedback_client)

    load_initializer(POSTHOG_DEVELOPMENT_ENABLED: "true")

    assert_same feedback_client, $posthog_feedback
    assert_nil $posthog
  end

  test "development opt-in does not initialize feedback in automated tests" do
    PostHog::Client.expects(:new).never

    load_initializer(POSTHOG_DEVELOPMENT_ENABLED: "true")

    assert_nil $posthog_feedback
  end

  private
    def load_initializer(**overrides)
      with_env_overrides({ POSTHOG_KEY: nil, POSTHOG_HOST: nil, POSTHOG_FEEDBACK_ENABLED: "true",
                          POSTHOG_DEVELOPMENT_ENABLED: "false" }.merge(overrides)) do
        load Rails.root.join("config/initializers/posthog.rb")
      end
    end
end
