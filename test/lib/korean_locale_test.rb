require "test_helper"
require "yaml"

class KoreanLocaleIntegrityTest < ActiveSupport::TestCase
  test "application translations retain English keys, placeholders and HTML" do
    files = Rails.root.glob("config/locales/**/{ko.yml,*.ko.yml}").reject { |path| path.to_s.include?("/defaults/") }
    assert files.any?

    files.each do |file|
      english = YAML.load_file(file.to_s.sub(/ko\.yml\z/, "en.yml")).fetch("en")
      korean = YAML.load_file(file).fetch("ko")
      english_values = flatten_values(english)

      flatten_values(korean).each do |key, value|
        source = english_values.fetch(key) { flunk "Unknown Korean translation: #{key}" }
        assert_equal source.class, value.class, key
        next unless value.is_a?(String)

        assert_equal source.scan(/%\{[^}]+\}/).sort, value.scan(/%\{[^}]+\}/).sort, key
        assert_equal source.scan(/<\/?[A-Za-z][^>]*>/), value.scan(/<\/?[A-Za-z][^>]*>/), key
      end
    end
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
