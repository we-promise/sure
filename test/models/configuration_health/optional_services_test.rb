require "test_helper"

class ConfigurationHealth::OptionalServicesTest < ActiveSupport::TestCase
  ENVIRONMENT = %w[
    LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_HOST SENTRY_DSN
    SKYLIGHT_AUTHENTICATION SKYLIGHT_ENABLED STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET
    STRIPE_MONTHLY_PRICE_ID STRIPE_ANNUAL_PRICE_ID POSTHOG_KEY POSTHOG_HOST
    POSTHOG_FEEDBACK_ENABLED POSTHOG_DEVELOPMENT_ENABLED LOGTAIL_API_KEY LOGTAIL_INGESTING_HOST
  ].index_with(nil).freeze

  setup do
    @health = ConfigurationHealth::OptionalServices.new
    @langfuse = OpenStruct.new(public_key: nil, secret_key: nil)
    @posthog = ActiveSupport::OrderedOptions.new
    @posthog.api_key = nil
    @posthog.host = "https://us.i.posthog.com"
    @posthog.development_enabled = false
    @posthog.feedback_enabled = true
    Langfuse.stubs(:configuration).returns(@langfuse)
    Sentry.stubs(:configuration).returns(nil)
    Rails.configuration.x.stubs(:posthog).returns(@posthog)
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Rails.stubs(:env).returns("test".inquiry)
  end

  test "absent optional services are informational and initialize no clients" do
    Langfuse.expects(:new).never
    Sentry.expects(:init).never
    Sentry.expects(:capture_exception).never
    Sentry.expects(:capture_message).never
    Stripe::StripeClient.expects(:new).never
    PostHog::Client.expects(:new).never
    Logtail::Logger.expects(:create_default_logger).never

    with_environment do
      checks = @health.checks
      assert_equal %i[langfuse sentry skylight stripe posthog logtail], checks.map(&:key)
      assert checks.all? { |check| check.status == :not_configured }
      assert checks.all? { |check| check.tone == :neutral }
      assert checks.all? { |check| check.settings.empty? }
    end
  end

  test "Langfuse host alone is optional and either single key is incomplete" do
    with_environment("LANGFUSE_HOST" => "https://private-host.test") do
      assert_equal :not_configured, @health.langfuse.status
    end
    %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY].each do |key|
      with_environment(key => "private-value") do
        check = @health.langfuse
        assert_equal :incomplete, check.status
        assert_equal [ (%w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY] - [ key ]).first ], check.settings
        assert_equal :warning, check.tone
        assert_no_match(/private-value/, check.inspect)
      end
    end
  end

  test "Langfuse uses the boot configuration as well as its runtime environment gate" do
    with_environment("LANGFUSE_PUBLIC_KEY" => "private-public", "LANGFUSE_SECRET_KEY" => "private-secret") do
      assert_equal :not_checked, @health.langfuse.status
      @langfuse.public_key = "private-public"
      @langfuse.secret_key = "private-secret"
      assert_equal :configured, @health.langfuse.status
      @langfuse.secret_key = "previous-secret"
      assert_equal [ :restart_required ], @health.langfuse.notes
    end
  end

  test "Sentry settings without an initialized SDK remain unverified" do
    with_environment("SENTRY_DSN" => "https://private-key@private-host.test/123") do
      check = @health.sentry
      assert_equal :not_checked, check.status
      assert_equal [ :restart_required ], check.notes
      assert_no_match(/private-/, check.inspect)
    end
  end

  test "Sentry reports its actual loaded configuration and enabled environment" do
    config = Sentry::Configuration.new
    config.dsn = "https://private-key@sentry.example.test/123"
    config.enabled_environments = [ "production" ]
    Sentry.stubs(:configuration).returns(config)

    with_environment do
      config.environment = "development"
      assert_equal :disabled, @health.sentry.status
      config.environment = "production"
      assert_equal :configured, @health.sentry.status
      assert_no_match(/private-key/, @health.sentry.inspect)
    end
  end

  test "explicit Skylight false disables it even if authentication exists" do
    with_environment("SKYLIGHT_AUTHENTICATION" => "private-token", "SKYLIGHT_ENABLED" => "FaLsE") do
      assert_equal :disabled, @health.skylight.status
      assert_equal [ :explicitly_disabled ], @health.skylight.notes
    end
  end

  test "explicit Skylight opt in without authentication is incomplete" do
    with_environment("SKYLIGHT_ENABLED" => "true") do
      assert_equal :incomplete, @health.skylight.status
      assert_equal [ "SKYLIGHT_AUTHENTICATION" ], @health.skylight.settings
    end
  end

  test "Skylight token and flag do not imply the SDK was loaded" do
    @health.stubs(:skylight_loaded?).returns(false)
    with_environment("SKYLIGHT_AUTHENTICATION" => "private-token", "SKYLIGHT_ENABLED" => "true") do
      assert_equal :not_checked, @health.skylight.status
      assert_equal [ :skylight_not_loaded ], @health.skylight.notes
    end
  end

  test "loaded Skylight respects its environment list and the SDK flag override" do
    @health.stubs(:skylight_loaded?).returns(true)
    Rails.application.config.stubs(:skylight).returns(OpenStruct.new(environments: [ "production" ]))
    with_environment("SKYLIGHT_AUTHENTICATION" => "private-token") do
      assert_equal :disabled, @health.skylight.status
      Rails.stubs(:env).returns("production".inquiry)
      assert_equal :configured, @health.skylight.status
    end
    Rails.stubs(:env).returns("development".inquiry)
    %w[true 0].each do |flag|
      with_environment("SKYLIGHT_AUTHENTICATION" => "private-token", "SKYLIGHT_ENABLED" => flag) do
        assert_equal :configured, @health.skylight.status
      end
    end
  end

  test "managed Stripe requires both credentials and both offered plan IDs" do
    with_environment("STRIPE_SECRET_KEY" => "private-secret", "STRIPE_WEBHOOK_SECRET" => "private-webhook") do
      check = @health.stripe
      assert_equal :incomplete, check.status
      assert_equal %w[STRIPE_MONTHLY_PRICE_ID STRIPE_ANNUAL_PRICE_ID], check.settings
    end
    with_environment(stripe_settings) do
      assert_equal :configured, @health.stripe.status
      assert_no_match(/private-/, @health.stripe.inspect)
    end
    with_environment(stripe_settings.merge("STRIPE_WEBHOOK_SECRET" => nil)) do
      assert_equal [ "STRIPE_WEBHOOK_SECRET" ], @health.stripe.settings
    end
  end

  test "self hosted Stripe does not require checkout prices or claim all processing is disabled" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    with_environment do
      assert_equal :not_configured, @health.stripe.status
      assert_equal :neutral, @health.stripe.tone
      assert_equal [ :self_hosted_checkout_disabled ], @health.stripe.notes
    end
    with_environment("STRIPE_SECRET_KEY" => "private-secret", "STRIPE_WEBHOOK_SECRET" => "private-webhook") do
      assert_equal :configured, @health.stripe.status
      assert_empty @health.stripe.settings
      assert_equal [ :self_hosted_checkout_disabled ], @health.stripe.notes
    end
  end

  test "Stripe price IDs alone still reveal missing credentials in self hosted mode" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    with_environment("STRIPE_MONTHLY_PRICE_ID" => "private-price") do
      assert_equal :incomplete, @health.stripe.status
      assert_equal %w[STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET], @health.stripe.settings
    end
  end

  test "PostHog reads boot loaded settings rather than later environment changes" do
    with_environment("POSTHOG_KEY" => "later-key", "POSTHOG_HOST" => "https://later-host.test") do
      assert_equal :not_configured, @health.posthog.status
    end
    @posthog.api_key = "private-key"
    with_environment do
      assert_equal :configured, @health.posthog.status
      assert_no_match(/private-key/, @health.posthog.inspect)
      @posthog.host = ""
      assert_equal :incomplete, @health.posthog.status
      assert_equal [ "POSTHOG_HOST" ], @health.posthog.settings
    end
  end

  test "PostHog browser gating does not misreport the server client as disabled" do
    @posthog.api_key = "private-key"
    with_environment do
      assert_equal :configured, @health.posthog.status
      assert_includes @health.posthog.notes, :browser_analytics_disabled
      Rails.stubs(:env).returns("production".inquiry)
      assert_not_includes @health.posthog.notes, :browser_analytics_disabled
      Rails.stubs(:env).returns("development".inquiry)
      assert_includes @health.posthog.notes, :browser_analytics_disabled
      @posthog.development_enabled = true
      assert_not_includes @health.posthog.notes, :browser_analytics_disabled
    end
  end

  test "shared PostHog feedback is separate from operator analytics and consent" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    Rails.stubs(:env).returns("production".inquiry)
    with_environment do
      assert_equal :not_configured, @health.posthog.status
      assert_includes @health.posthog.notes, :shared_feedback_configured
      @posthog.api_key = "private-key"
      @posthog.feedback_enabled = false
      assert_equal :configured, @health.posthog.status
      assert_includes @health.posthog.notes, :shared_feedback_disabled
    end
  end

  test "Logtail needs both fields and is used only in production" do
    with_environment("LOGTAIL_API_KEY" => "private-key") do
      assert_equal :incomplete, @health.logtail.status
      assert_equal [ "LOGTAIL_INGESTING_HOST" ], @health.logtail.settings
    end
    with_environment("LOGTAIL_API_KEY" => "private-key", "LOGTAIL_INGESTING_HOST" => "private-host") do
      assert_equal :disabled, @health.logtail.status
      Rails.stubs(:env).returns("production".inquiry)
      assert_equal :configured, @health.logtail.status
      assert_no_match(/private-/, @health.logtail.inspect)
    end
  end

  private
    def with_environment(overrides = {}, &block)
      ClimateControl.modify(ENVIRONMENT.merge(overrides), &block)
    end

    def stripe_settings
      {
        "STRIPE_SECRET_KEY" => "private-secret", "STRIPE_WEBHOOK_SECRET" => "private-webhook",
        "STRIPE_MONTHLY_PRICE_ID" => "private-monthly", "STRIPE_ANNUAL_PRICE_ID" => "private-annual"
      }
    end
end
