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

  test "effective_categorization_provider defaults to llm and follows the Setting and ENV choice" do
    assert_equal "llm", effective_categorization_provider

    Setting.categorization_provider = "jev"
    Setting.clear_cache
    assert_equal "jev", effective_categorization_provider

    ENV["CATEGORIZATION_PROVIDER"] = "llm"
    assert_equal "llm", effective_categorization_provider, "ENV wins over Setting, as the config does"
  ensure
    Setting.categorization_provider = nil
    Setting.clear_cache
  end

  test "an unsupported CATEGORIZATION_PROVIDER is ignored rather than passed through" do
    Setting.categorization_provider = "openai"
    Setting.clear_cache

    assert_equal "llm", effective_categorization_provider

    ENV["CATEGORIZATION_PROVIDER"] = "jev"
    assert_equal "jev", effective_categorization_provider
  ensure
    Setting.categorization_provider = nil
    Setting.clear_cache
  end

  test "jev_configured? is false with no credential and true with one" do
    assert_not jev_configured?

    ENV["JEV_API_KEY"] = "jev-test"
    assert jev_configured?

    ENV.delete("JEV_API_KEY")
    Setting.jev_api_key = "jev-setting"
    assert jev_configured?
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

  test "jev_model defaults to jev-latest and honours ENV" do
    assert_equal "jev-latest", jev_model

    ENV["JEV_MODEL"] = "jev-2"
    assert_equal "jev-2", jev_model
  end

  test "jev_effective_host and jev_effective_proxied? distinguish TypeSafe from a gateway" do
    assert_equal "api.typesafe.ai", jev_effective_host
    assert_not jev_effective_proxied?

    ENV["JEV_ENDPOINT"] = "https://eu.openrouter.ai/api/alpha/decisions"
    assert_equal "eu.openrouter.ai", jev_effective_host
    assert jev_effective_proxied?
  end

  test "categorization_shadow_summary samples comparisons, agreement and named disagreements" do
    family = families(:dylan_family)
    coffee = family.categories.create!(name: "Coffee")
    groceries = family.categories.create!(name: "Groceries")
    other = families(:empty)
    other.ai_comparisons.create!(feature: "categorize", agreed: true, subject_type: "Transaction",
                                 primary_value: nil, shadow_value: nil)

    summary = categorization_shadow_summary(family)
    assert_equal 0, summary[:sampled]
    assert_nil summary[:agreement]
    assert_empty summary[:disagreements]

    3.times { family.ai_comparisons.create!(feature: "categorize", agreed: true, subject_type: "Transaction",
                                            primary_value: coffee.id, shadow_value: coffee.id) }
    disagree = family.ai_comparisons.create!(feature: "categorize", agreed: false, subject_type: "Transaction",
                                             primary_value: coffee.id, shadow_value: groceries.id)

    summary = categorization_shadow_summary(family)
    assert_equal 4, summary[:sampled], "the other family's rows are not counted"
    assert_in_delta 75.0, summary[:agreement], 0.01
    assert_equal [ disagree ], summary[:disagreements].to_a
    assert_equal "Groceries", summary[:disagreements].sole.shadow_name
    assert_equal "Coffee", summary[:disagreements].sole.primary_name
  ensure
    clear_setting_fields("categorization_provider")
  end

  private
    def clear_setting_fields(*fields)
      fields.each { |field| Setting.public_send("#{field}=", nil) }
      Setting.clear_cache
    end
end
