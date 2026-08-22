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

  # YAML silently resolves duplicate keys by letting the last occurrence win,
  # so a duplicated key shadows the earlier definition without any warning
  # (see #1506 / #1502, where a stale `transactions.merge_duplicate` string
  # shadowed — or was shadowed by — the `merge_duplicate.success/failure`
  # mapping in several locales). Parse the raw YAML AST so duplicates can't
  # sneak back in.
  def test_no_duplicate_keys_within_locale_files
    offenses = []

    Dir[File.expand_path("../config/locales/**/*.yml", __dir__)].sort.each do |file|
      Psych.parse_stream(File.read(file), filename: file).children.each do |doc|
        offenses.concat(duplicate_key_offenses(doc.root, [], file))
      end
    end

    assert_empty offenses,
                 "Duplicate keys found in locale files (the last occurrence silently wins):\n" \
                 "#{offenses.map { |offense| "  #{offense}" }.join("\n")}"
  end

  private
    def german_locale_paths
      @german_locale_paths ||= locale_paths.select { |path| path.basename.to_s.match?(/(^|[._-])de\.yml\z/) }
    end

    def locale_paths
      @locale_paths ||= GERMAN_COVERAGE_GLOBS.flat_map { |glob| Pathname.pwd.glob(glob) }.uniq
    end

    def duplicate_key_offenses(node, path, file)
      offenses = []

      case node
      when Psych::Nodes::Mapping
        first_definition_lines = {}

        node.children.each_slice(2) do |key_node, value_node|
          if key_node.is_a?(Psych::Nodes::Scalar)
            key_path = path + [ key_node.value ]

            if (first_line = first_definition_lines[key_node.value])
              offenses << "#{file}:#{key_node.start_line + 1} duplicate key `#{key_path.join(".")}` (first defined on line #{first_line})"
            else
              first_definition_lines[key_node.value] = key_node.start_line + 1
            end

            offenses.concat(duplicate_key_offenses(value_node, key_path, file))
          else
            offenses.concat(duplicate_key_offenses(value_node, path, file))
          end
        end
      when Psych::Nodes::Sequence
        node.children.each { |child| offenses.concat(duplicate_key_offenses(child, path, file)) }
      end

      offenses
    end
end
