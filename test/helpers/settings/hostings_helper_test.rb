require "test_helper"

# Settings::HostingsHelper: the values the Self-Hosting page renders for the categorization
# provider. ENV and Setting are the real inputs; Setting's cache is cleared around each one.
class Settings::HostingsHelperTest < ActionView::TestCase
  include Settings::HostingsHelper

  AI_VARIABLES = %w[
    OPENAI_ACCESS_TOKEN ANTHROPIC_ACCESS_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL JEV_API_KEY JEV_ENDPOINT JEV_MODEL
    JEV_REQUEST_TIMEOUT CATEGORIZATION_PROVIDER OPENROUTER_API_KEY
  ].freeze

  setup do
    @previous = AI_VARIABLES.index_with { ENV.key?(_1) ? ENV[_1] : :__unset }
    AI_VARIABLES.each { ENV.delete(_1) }
    clear_setting_fields("jev_api_key", "jev_endpoint", "jev_model", "categorization_provider")
  end

  teardown do
    AI_VARIABLES.each { _1.nil? || @previous[_1] == :__unset ? ENV.delete(_1) : ENV[_1] = @previous[_1] }
    clear_setting_fields("jev_api_key", "jev_endpoint", "jev_model", "categorization_provider")
  end

  test "an OpenRouter key alone does not turn Jev on" do
    ENV["OPENROUTER_API_KEY"] = "or-test"
    Setting.categorization_provider = "jev"
    Setting.clear_cache

    assert_not jev_configured?, "JEV_API_KEY or the jev_api_key setting is required, not OPENROUTER_API_KEY"
    assert_not Ai::LegacyEnvConfig::Jev.configured?
  end

  test "jev_endpoint is the redacted endpoint, without userinfo, query or fragment" do
    ENV["JEV_ENDPOINT"] = "https://user:pass@gw.example.test/v1/systemone?key=secret#frag"

    assert_equal "https://gw.example.test/v1/systemone", jev_endpoint
  end

  private
    def clear_setting_fields(*fields)
      fields.each { |field| Setting.public_send("#{field}=", nil) }
      Setting.clear_cache
    end
end
