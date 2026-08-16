require "i18n/tasks"
require "pathname"
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
    def german_locale_paths
      @german_locale_paths ||= locale_paths.select { |path| path.basename.to_s.match?(/(^|[._-])de\.yml\z/) }
    end

    def locale_paths
      @locale_paths ||= GERMAN_COVERAGE_GLOBS.flat_map { |glob| Pathname.pwd.glob(glob) }.uniq
    end
end
