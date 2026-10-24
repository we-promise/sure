require "test_helper"
require Rails.root.join("test/support/application_locale_catalog").to_s

class SupportedLocaleI18nTest < ActiveSupport::TestCase
  Catalog = ApplicationLocaleCatalog
  COUNTS = [ 0, 1, 2, 3, 5, 11, 21, 22, 101, 1.5 ].freeze

  # A whitespace grouping separator is formatting data, not a missing label.
  # Catalan has no counterpart for English "there" in the anonymous "Hey there"
  # greeting; its explicitly empty fragment leaves the translated greeting intact.
  def intentional_blank?(locale, key, value)
    return true if key.start_with?("number.") && key.end_with?(".delimiter") && value.is_a?(String)

    locale == "ca" && key == "chats.ai_greeting.there" && value == ""
  end

  test "locale mapping keys cannot be silently parsed as YAML booleans" do
    failures = []
    Rails.root.glob("config/locales/**/*.yml").sort.each do |path|
      suffix = path.basename(".yml").to_s.split(".").last
      next unless LanguagesHelper::SUPPORTED_LOCALES.include?(suffix)

      inspect_keys = lambda do |node, parents|
        case node
        when Psych::Nodes::Mapping
          node.children.each_slice(2) do |key, value|
            next unless key.is_a?(Psych::Nodes::Scalar)

            name = parents + [ key.value ]
            if key.plain && key.value.match?(/\A(?:true|false|yes|no|on|off)\z/i)
              failures << "#{path.relative_path_from(Rails.root)}:#{key.start_line + 1} #{name.join('.')}"
            end
            inspect_keys.call(value, name)
          end
        when Psych::Nodes::Sequence
          node.children.each { |child| inspect_keys.call(child, parents) }
        end
      end
      inspect_keys.call(Psych.parse(path.read).root, [])
    end
    assert_empty failures, "Quote boolean-like translation keys so their names survive YAML parsing:\n#{failures.join("\n")}"
  end

  LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
    test "#{locale} preserves ordered translation arrays and their placeholders" do
      english = Catalog.messages(Catalog.reference)
      translated = Catalog.messages(Catalog.catalog.fetch(locale))
      failures = []
      english.each do |key, source|
        next unless source.is_a?(Array) && translated.key?(key)

        target = translated[key]
        unless target.is_a?(Array) && target.length == source.length
          failures << "#{key}: expected #{source.length} ordered values"
          next
        end
        source.zip(target).each_with_index do |(original, text), index|
          next if original.nil? && text.nil?

          if !text.is_a?(original.class) || (original.is_a?(String) && !Catalog.blank?(original) && Catalog.blank?(text))
            failures << "#{key}[#{index}]: type or empty value changed"
          elsif Catalog.message_tokens(key, original) != Catalog.message_tokens(key, text) || Catalog.html_signature(original) != Catalog.html_signature(text)
            failures << "#{key}[#{index}]: placeholders or HTML changed"
          end
        end
      end
      assert_empty failures, "#{locale} array failures:\n#{failures.join("\n")}"
    end

    test "#{locale} explicitly covers every application message without fallback" do
      english = Catalog.messages(Catalog.reference)
      translated = Catalog.messages(Catalog.catalog.fetch(locale))
      missing = english.keys - translated.keys
      assert_empty missing, "#{locale} missing #{missing.length} messages:\n#{missing.first(30).join("\n")}"

      blank = (english.keys & translated.keys).select do |key|
        !Catalog.blank?(english[key]) && Catalog.blank?(translated[key]) && !intentional_blank?(locale, key, translated[key])
      end
      assert_empty blank, "#{locale} empty translations: #{blank.join(', ')}"
    end

    test "#{locale} preserves named interpolation across plural message forms" do
      english = Catalog.messages(Catalog.reference)
      translated = Catalog.messages(Catalog.catalog.fetch(locale))
      differences = (english.keys & translated.keys).filter_map do |key|
        expected = Catalog.message_tokens(key, english[key])
        actual = Catalog.message_tokens(key, translated[key])
        "#{key}: #{expected.inspect} -> #{actual.inspect}" unless expected == actual
      end
      assert_empty differences, "#{locale} interpolation mismatch:\n#{differences.first(30).join("\n")}"
    end

    test "#{locale} plural messages render all relevant counts with explicit forms" do
      english = Catalog.messages(Catalog.reference)
      translated = Catalog.messages(Catalog.catalog.fetch(locale))
      rule = I18n.t("i18n.plural.rule", locale: locale, resolve: false, fallback: false, default: nil)
      keys = (english.keys & translated.keys).select { |key| Catalog.plural?(english[key]) || Catalog.plural?(translated[key]) }
      failures = []
      keys.each do |key|
        target = translated[key]
        arguments = Catalog.tokens(target).to_h { |name| [ name.to_sym, 2 ] }
        COUNTS.each do |count|
          if Catalog.plural?(target)
            branch = count.zero? && target.key?("zero") ? :zero : (rule.respond_to?(:call) ? rule.call(count) : (count == 1 ? :one : :other))
            unless target.key?(branch.to_s)
              failures << "#{key} count=#{count} missing #{branch}"
              next
            end
          end
          begin
            text = I18n.t(key, **arguments.merge(locale: locale, count: count, fallback: false, raise: true))
            failures << "#{key} count=#{count} did not produce complete text" unless text.is_a?(String) && text.present? && Catalog.tokens(text).empty?
          rescue I18n::ArgumentError => error
            failures << "#{key} count=#{count}: #{error.class}"
          end
        end
      end
      assert_empty failures, "#{locale} plural failures:\n#{failures.first(40).join("\n")}"
    end

    test "#{locale} preserves translated HTML elements and attributes" do
      english = Catalog.messages(Catalog.reference)
      translated = Catalog.messages(Catalog.catalog.fetch(locale))
      failures = []
      (english.keys & translated.keys).each do |key|
        reference = english[key]
        target = translated[key]
        targets = Catalog.plural?(target) ? target : { "other" => target }
        targets.each do |branch, text|
          source = Catalog.plural?(reference) ? (reference[branch] || reference["other"]) : reference
          next unless source.is_a?(String) && text.is_a?(String)

          failures << "#{key}.#{branch}" unless Catalog.html_signature(source) == Catalog.html_signature(text)
        end
      end
      assert_empty failures, "#{locale} changed HTML:\n#{failures.first(30).join("\n")}"
    end

    test "#{locale} formats dates and decimal values without English fallback" do
      [ :default, :long, :short, :month_year ].each do |format|
        rendered = I18n.l(Date.new(2026, 1, 2), locale: locale, format: format, fallback: false, raise: true)
        assert rendered.is_a?(String) && rendered.present?
        refute_match(/translation missing|%[YmdBAbe]/, rendered)
      end
      separator = I18n.t("number.format.separator", locale: locale, fallback: false, raise: true)
      delimiter = I18n.t("number.format.delimiter", locale: locale, fallback: false, raise: true)
      rendered = ActiveSupport::NumberHelper.number_to_delimited("12345.6789", locale: locale)
      assert_equal "12#{delimiter}345#{separator}6789", rendered
    end
  end
end
