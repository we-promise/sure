require "test_helper"

class SentryTest < ActiveSupport::TestCase
  test "errors reported through Rails.error go to Sentry" do
    config = Sentry::Configuration.new
    Sentry.stubs(:init).yields(config)

    with_env_overrides("SENTRY_DSN" => "https://key@sentry.example/1") do
      load Rails.root.join("config/initializers/sentry.rb")
    end

    assert config.rails.register_error_subscriber
  end
end
