require "test_helper"
require "yaml"

class KoreanLocaleIntegrityTest < ActiveSupport::TestCase
  # English builds these in Ruby (Integer#ordinalize), so only Korean has a key.
  KOREAN_ONLY_KEYS = %w[recurring_transactions.frequency.numbered_day].freeze

  test "application translations retain English keys, placeholders and HTML" do
    files = Rails.root.glob("config/locales/**/{ko.yml,*.ko.yml}").reject { |path| path.to_s.include?("/defaults/") }
    assert files.any?

    files.each do |file|
      english = YAML.load_file(file.to_s.sub(/ko\.yml\z/, "en.yml")).fetch("en")
      korean = YAML.load_file(file).fetch("ko")
      english_values = flatten_values(english)

      flatten_values(korean).each do |key, value|
        next if KOREAN_ONLY_KEYS.include?(key)

        source = english_values.fetch(key) { flunk "Unknown Korean translation: #{key}" }
        assert_equal source.class, value.class, key
        next unless value.is_a?(String)

        assert_equal source.scan(/%\{[^}]+\}/).sort, value.scan(/%\{[^}]+\}/).sort, key
        assert_equal source.scan(/<\/?[A-Za-z][^>]*>/), value.scan(/<\/?[A-Za-z][^>]*>/), key
      end
    end
  end

  test "the AI dig-in prompt separates its fields with real line breaks" do
    prompt = I18n.t("insights.dig_in.prompt", locale: :ko)

    assert_not_includes prompt, "\\n"
    assert_equal I18n.t("insights.dig_in.prompt", locale: :en).count("\n"), prompt.count("\n")
  end

  test "the Sharesight cash anchor date label is a string in English and Korean" do
    assert_equal "On", I18n.t("sharesight_accounts.settings_fields.cash_anchor_on", locale: :en)
    assert_kind_of String, I18n.t("sharesight_accounts.settings_fields.cash_anchor_on", locale: :ko)
  end

  private
    def flatten_values(value, path = [], result = {})
      case value
      when Hash
        value.each { |key, child| flatten_values(child, path + [ key.to_s ], result) }
      when Array
        value.each_with_index { |child, index| flatten_values(child, path + [ index.to_s ], result) }
      else
        result[path.join(".")] = value
      end
      result
    end
end
