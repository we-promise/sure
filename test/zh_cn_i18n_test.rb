require "test_helper"
require "yaml"

class ZhCnI18nTest < ActiveSupport::TestCase
  LOCALE = "zh-CN".freeze
  # Exclude Rails' generic defaults only in defaults/*.yml. Application model
  # errors and helpers in other files remain part of the coverage contract.
  DEFAULT_FRAMEWORK_ROOTS = %w[activerecord date datetime errors helpers number support time].freeze
  PLURAL_KEYS = %w[zero one two few many other].freeze

  test "every English application key has an explicit Simplified Chinese value" do
    english = application_leaves("en")
    chinese = application_leaves(LOCALE)

    assert_not_empty english, "The English reference must be loaded from the application locale files"
    assert_empty english.keys - chinese.keys,
      "Missing explicit zh-CN keys (English fallback does not count):\n#{(english.keys - chinese.keys).sort.join("\n")}"
  end

  test "nonempty English application values never have empty Chinese translations" do
    english = application_leaves("en")
    chinese = application_leaves(LOCALE)
    empty = english.filter_map do |key, value|
      key if !empty_translation?(value) && empty_translation?(chinese[key])
    end

    assert_empty empty, "Blank zh-CN translations for nonempty English values:\n#{empty.sort.join("\n")}"
  end

  test "application translations retain the same named interpolation variables" do
    english = application_leaves("en")
    chinese = application_leaves(LOCALE)
    mismatches = (english.keys & chinese.keys).filter_map do |key|
      expected = interpolation_names(english[key])
      actual = interpolation_names(chinese[key])
      "#{key}: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
    end

    assert_empty mismatches, "Chinese interpolation mismatches:\n#{mismatches.sort.join("\n")}"
  end

  test "every application plural renders zero one and two without English fallback" do
    plurals = plural_messages(locale_catalog.fetch(:application).fetch("en"))
    assert_not_empty plurals, "The plural coverage test must exercise application messages"

    plurals.each do |key, english|
      chinese = locale_catalog.fetch(:application).fetch(LOCALE).dig(*key.split("."))
      assert chinese.is_a?(Hash), "#{key} must retain a plural mapping in zh-CN"
      assert chinese.key?("other"), "#{key} needs a Chinese other branch"
      assert_empty chinese.keys - PLURAL_KEYS, "#{key} has a malformed plural mapping"
      values = interpolation_names(english).to_h { |name| [ name.to_sym, 2 ] }

      [ 0, 1, 2 ].each do |count|
        text = I18n.t(key, **values.merge(locale: LOCALE, count: count, fallback: false, raise: true))
        assert text.is_a?(String) && text.present?, "#{key} did not render at count=#{count}"
        assert_empty interpolation_names(text), "#{key} left placeholders at count=#{count}: #{text}"
        refute_match(/translation missing/i, text, "#{key} at count=#{count}")
      end
    end
  end

  test "Chinese dates use year month day order and Chinese weekday and time names" do
    date = Date.new(2026, 1, 2)
    time = Time.utc(2026, 1, 2, 3, 4, 5)

    assert_equal [ :year, :month, :day ], explicit_translation("date.order")
    assert_equal "2026-01-02", I18n.l(date, locale: LOCALE, format: :default, fallback: false)
    assert_equal "2026年01月02日", I18n.l(date, locale: LOCALE, format: :long, fallback: false)
    assert_equal "01月02日", I18n.l(date, locale: LOCALE, format: :short, fallback: false)
    assert_equal "2026年01月", I18n.l(date, locale: LOCALE, format: :month_year, fallback: false)
    assert_equal "2026年01月02日 星期五 03:04:05", I18n.l(time, locale: LOCALE, format: :default, fallback: false)
    assert_equal "2026年01月02日 03:04", I18n.l(time, locale: LOCALE, format: :long, fallback: false)
    assert_equal %w[星期日 星期一 星期二 星期三 星期四 星期五 星期六], explicit_translation("date.day_names")
    assert_equal "上午", explicit_translation("time.am")
    assert_equal "下午", explicit_translation("time.pm")
    assert_equal "2天", I18n.t("datetime.distance_in_words.x_days", locale: LOCALE, count: 2, fallback: false, raise: true)
  end

  test "Chinese numbers use decimal points and comma grouping without losing supplied precision" do
    assert_equal ".", explicit_translation("number.format.separator")
    assert_equal ",", explicit_translation("number.format.delimiter")
    assert_equal "%n%", explicit_translation("number.percentage.format.format")
    assert_equal "1,234,567.8901", ActiveSupport::NumberHelper.number_to_delimited(BigDecimal("1234567.8901"), locale: LOCALE)
    assert_equal "-1,234.50", ActiveSupport::NumberHelper.number_to_delimited("-1234.50", locale: LOCALE)
    assert_equal "12.5%", ActiveSupport::NumberHelper.number_to_percentage(BigDecimal("12.5"), precision: 1, locale: LOCALE)
  end

  private
    def locale_catalog
      self.class.locale_catalog
    end

    def self.locale_catalog
      @locale_catalog ||= begin
        application = { "en" => {}, LOCALE => {} }
        all = { "en" => {}, LOCALE => {} }
        Rails.root.glob("config/locales/**/*.yml").sort.each do |path|
          document = YAML.safe_load(path.read, permitted_classes: [ Date, Time, Symbol ], aliases: true, filename: path.to_s)
          document.each do |locale, translations|
            locale = locale.to_s
            next unless application.key?(locale) && translations.is_a?(Hash)

            tree = translations.deep_stringify_keys
            all[locale] = all[locale].deep_merge(tree)
            if path.relative_path_from(Rails.root).to_s.start_with?("config/locales/defaults/")
              tree = tree.except(*DEFAULT_FRAMEWORK_ROOTS)
            end
            application[locale] = application[locale].deep_merge(tree)
          end
        end
        { application: application, all: all }
      end
    end

    def application_leaves(locale)
      flatten_leaves(locale_catalog.fetch(:application).fetch(locale))
    end

    def flatten_leaves(tree, prefix = nil)
      return { prefix => tree } unless tree.is_a?(Hash)

      tree.each_with_object({}) do |(key, value), result|
        result.merge!(flatten_leaves(value, [ prefix, key ].compact.join(".")))
      end
    end

    def empty_translation?(value)
      value.nil? || (value.is_a?(String) && value.strip.empty?) || (value.respond_to?(:empty?) && value.empty?)
    end

    def interpolation_names(value)
      case value
      when String
        value.scan(/(?<!%)%\{([^}]+)\}|(?<!%)%<([^>]+)>/).flatten.compact.uniq.sort
      when Array
        value.flat_map { |child| interpolation_names(child) }.uniq.sort
      when Hash
        value.values.flat_map { |child| interpolation_names(child) }.uniq.sort
      else
        []
      end
    end

    def plural_messages(tree, prefix = nil)
      return {} unless tree.is_a?(Hash)
      return { prefix => tree } if tree.key?("other") && (tree.keys - PLURAL_KEYS).empty?

      tree.each_with_object({}) do |(key, value), result|
        result.merge!(plural_messages(value, [ prefix, key ].compact.join(".")))
      end
    end

    def explicit_translation(key)
      expected = locale_catalog.fetch(:all).fetch(LOCALE).dig(*key.split("."))
      assert_not_nil expected, "Missing explicit Chinese formatting key: #{key}"
      actual = I18n.t(key, locale: LOCALE, fallback: false, raise: true)
      assert_equal expected, actual, "#{key} must resolve to the explicit Chinese value"
      actual
    end
end
