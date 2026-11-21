require "test_helper"
require_relative "chat_system_test"

# The env scoping shared by every e2e test, checked without making a live request.
class AiE2eHelperTest < ActiveSupport::TestCase
  include AiE2eHelper

  # AiE2eHelper skips its own tests unless AI_E2E=1; this one checks the helper offline.
  def before_setup
    @previous_ai_e2e = ENV["AI_E2E"]
    ENV["AI_E2E"] = "1"
    super
  end

  def after_teardown
    super
  ensure
    ENV["AI_E2E"] = @previous_ai_e2e
  end

  test "with_live_ai enables the network for its scope without AI_LIVE in the environment" do
    with_env_overrides("AI_LIVE" => nil, "RECORD_CASSETTES" => nil) do
      assert_equal "1", with_live_ai { ENV["AI_LIVE"] }
      assert_equal "1", with_live_ai(jev: true) { ENV["AI_LIVE"] }
      assert_nil ENV["AI_LIVE"], "the caller's AI_LIVE was restored"
    end
  end

  test "a Kilo run ignores the host's stored Jev key while a Jev run keeps it" do
    with_env_overrides("JEV_API_KEY" => nil) do
      Setting.stubs(:jev_api_key).returns("host-key")

      with_live_ai { assert_not Ai::LegacyEnvConfig::Jev.configured? }
      with_live_ai(jev: true) { assert Ai::LegacyEnvConfig::Jev.configured? }
    end
  end

  test "the Kilo gateway URL can be overridden for both live suites" do
    with_env_overrides("KILO_BASE_URL" => "https://gateway.example.test/v1") do
      assert_equal "https://gateway.example.test/v1", send(:kilo_env)[:OPENAI_URI_BASE]
    end
  end

  test "the chat system test leaves the browser alone when AI_E2E is unset" do
    with_env_overrides("AI_E2E" => nil) do
      system_test = AiE2eChatSystemTest.new("chat round-trip")
      system_test.define_singleton_method(:page) { flunk "Selenium was started for an offline e2e run" }

      assert_nil system_test.send(:reset_viewport)
    end
  end
end
