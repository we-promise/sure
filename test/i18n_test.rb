require "i18n/tasks"
require "pathname"
require "set"
require "yaml"

# We're currently skipping some i18n tests to speed up development.  Eventually, we'll make a dedicated
# project for getting i18n working.  More details on that here:
# https://github.com/maybe-finance/maybe/issues/1225
class I18nTest < ActiveSupport::TestCase
  GERMAN_COVERAGE_GLOBS = [
    "config/locales/breadcrumbs/*.yml",
    "config/locales/doorkeeper.*.yml",
    "config/locales/mailers/**/*.yml",
    "config/locales/models/**/*.yml",
    "config/locales/views/**/*.yml"
  ]

  def setup
    @i18n = I18n::Tasks::BaseTask.new
  end

  def test_german_locale_files_parse
    german_locale_paths.each do |path|
      assert_nothing_raised do
        YAML.load_file(path, aliases: true)
      end
    end
  end

  def test_german_app_locale_covers_english_keys
    missing_keys = english_app_locale_leaves.keys.filter_map do |key|
      key unless translation_present?(german_app_locale_tree, key)
    end

    assert_empty missing_keys.sort, "Missing German i18n keys:\n#{missing_keys.sort.join("\n")}"
  end

  def test_german_app_locale_interpolations_match_english
    mismatches = english_app_locale_leaves.filter_map do |key, english_value|
      next unless english_value.is_a?(String)

      german_value = translation_at(german_app_locale_tree, key)
      next if german_value.nil?

      expected_interpolations = interpolation_keys(english_value)
      german_values =
        if german_value.is_a?(Hash)
          flatten_leaves(german_value).values.grep(String)
        else
          [ german_value ]
        end

      bad_values = german_values.reject { |value| interpolation_keys(value) == expected_interpolations }
      "#{key}: expected #{expected_interpolations.to_a.sort}, got #{bad_values.map { |value| interpolation_keys(value).to_a.sort }.uniq}" if bad_values.any?
    end

    assert_empty mismatches, "German i18n interpolation mismatches:\n#{mismatches.join("\n")}"
  end

  def test_no_missing_keys
    skip "Skipping missing keys test"
    missing_keys = @i18n.missing_keys(locales: [ :en ])
    assert_empty missing_keys,
                 "Missing #{missing_keys.leaves.count} i18n keys, run `i18n-tasks missing' to show them"
  end

  def test_no_unused_keys
    skip "Skipping unused keys test"
    unused_keys = @i18n.unused_keys(locales: [ :en ])
    assert_empty unused_keys,
                 "#{unused_keys.leaves.count} unused i18n keys, run `i18n-tasks unused' to show them"
  end

  def test_files_are_normalized
    skip "Skipping file normalization test"
    non_normalized = @i18n.non_normalized_paths(locales: [ :en ])
    error_message = "The following files need to be normalized:\n" \
                    "#{non_normalized.map { |path| "  #{path}" }.join("\n")}\n" \
                    "Please run `i18n-tasks normalize' to fix"
    assert_empty non_normalized, error_message
  end

  def test_no_inconsistent_interpolations
    skip "Skipping inconsistent interpolations test"
    inconsistent_interpolations = @i18n.inconsistent_interpolations(locales: [ :en ])
    error_message = "#{inconsistent_interpolations.leaves.count} i18n keys have inconsistent interpolations.\n" \
                    "Please run `i18n-tasks check-consistent-interpolations' to show them"
    assert_empty inconsistent_interpolations, error_message
  end

  private
    def english_app_locale_leaves
      @english_app_locale_leaves ||= flatten_leaves(english_app_locale_tree)
    end

    def english_app_locale_tree
      @english_app_locale_tree ||= locale_tree("en")
    end

    def german_app_locale_tree
      @german_app_locale_tree ||= locale_tree("de")
    end

    def german_locale_paths
      @german_locale_paths ||= locale_paths.select { |path| path.basename.to_s.match?(/(^|[._-])de\.yml\z/) }
    end

    def locale_tree(locale)
      locale_paths.each_with_object({}) do |path, tree|
        data = YAML.load_file(path, aliases: true) || {}
        deep_merge!(tree, data.fetch(locale, {}))
      end
    end

    def locale_paths
      @locale_paths ||= GERMAN_COVERAGE_GLOBS.flat_map { |glob| Pathname.pwd.glob(glob) }.uniq
    end

    def deep_merge!(target, source)
      source.each do |key, value|
        if target[key].is_a?(Hash) && value.is_a?(Hash)
          deep_merge!(target[key], value)
        else
          target[key] = value
        end
      end

      target
    end

    def flatten_leaves(value, prefix = [], result = {})
      case value
      when Hash
        value.each { |key, child| flatten_leaves(child, prefix + [ key.to_s ], result) }
      else
        result[prefix.join(".")] = value
      end

      result
    end

    def translation_at(tree, key)
      key.split(".").reduce(tree) do |current, segment|
        return nil unless current.is_a?(Hash) && current.key?(segment)

        current[segment]
      end
    end

    def translation_present?(tree, key)
      value = translation_at(tree, key)
      return false if value.nil?

      true
    end

    def interpolation_keys(value)
      value.scan(/%\{([^}]+)\}/).flatten.to_set
    end
end
