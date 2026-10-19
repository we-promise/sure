# frozen_string_literal: true

require "test_helper"

class CurrencyPasteSymbolsTest < ActiveSupport::TestCase
  PARSER_PATH = Rails.root.join("app/javascript/utils/parse_amount_paste.js")

  # parse_amount_paste.js hardcodes the letter-free currency symbols from
  # config/currencies.yml, so a symbol added or changed there must be mirrored
  # in CURRENCY_SYMBOL or pasted amounts carrying it stop being parsed.
  test "paste parser symbols match the letter-free symbols in currencies.yml" do
    expected = letter_free_symbols
    actual = parser_symbols

    assert_equal expected.sort, actual.sort, <<~MESSAGE
      CURRENCY_SYMBOL in app/javascript/utils/parse_amount_paste.js is out of sync with config/currencies.yml.

      Missing from the parser: #{(expected - actual).join(" ")}
      Not in currencies.yml: #{(actual - expected).join(" ")}
    MESSAGE
  end

  test "letter-free currency symbols fit in a regex character class" do
    multi_character = letter_free_symbols.select { |symbol| symbol.length > 1 }

    assert_empty multi_character,
      "CURRENCY_SYMBOL is a character class, so it cannot match these symbols: #{multi_character.join(" ")}"
  end

  private
    def letter_free_symbols
      Money::Currency.all.values.map { |currency| currency["symbol"] }.compact_blank.uniq.grep_v(/\p{L}/)
    end

    def parser_symbols
      symbol_class = PARSER_PATH.read[/const CURRENCY_SYMBOL = "\[(.+?)\]"/, 1]
      assert symbol_class, "expected CURRENCY_SYMBOL to be a character class in #{PARSER_PATH.relative_path_from(Rails.root)}"

      symbol_class.chars
    end
end
