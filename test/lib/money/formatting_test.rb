require "test_helper"

class Money::FormattingTest < ActiveSupport::TestCase
  CURRENCIES = %w[USD EUR JPY KWD CAD MXN BRL GBP INR PLN HUF CHF].freeze
  AMOUNTS = %w[
    0 0.004 -0.004 0.005 -0.005 0.0049 1 -1 12.345 -12.345 999.995 -999.995
    1234.5 -1234.5 1000000 -1234567.891 123456789012.346
  ].map { BigDecimal(_1) }.freeze
  OPTIONS = [ { precision: 0 }, { precision: 4 }, { unit: "" }, { format: "%n %u" }, { signify_positive: true } ].freeze

  test "formats exactly like number_to_currency in every locale" do
    I18n.available_locales.each do |locale|
      I18n.with_locale(locale) do
        CURRENCIES.each do |currency|
          AMOUNTS.each { |amount| assert_same_as_number_to_currency Money.new(amount, currency), locale }
        end

        OPTIONS.each do |options|
          [ BigDecimal("-0.005"), BigDecimal("-1234.5") ].each do |amount|
            assert_same_as_number_to_currency Money.new(amount, "EUR"), locale, options
          end
        end
      end
    end
  end

  test "an explicit locale keeps the current locale's number settings" do
    money = Money.new(BigDecimal("-1234.5"), "EUR")

    I18n.with_locale(:en) do
      expected = ActiveSupport::NumberHelper.number_to_currency(money.amount, money.format_options(:de))
      assert_equal expected, money.format(locale: :de)
    end
  end

  test "plain formatting does not go through number_to_currency" do
    money = Money.new(BigDecimal("1234.5"), "USD")
    money.expects(:number_to_currency).never

    assert_equal "$1,234.50", money.format
  end

  private
    def assert_same_as_number_to_currency(money, locale, options = {})
      expected = ActiveSupport::NumberHelper.number_to_currency(money.amount, money.format_options(locale).merge(options))
      assert_equal expected, money.format(options), "#{locale} #{money.currency.iso_code} #{money.amount.to_s("F")} #{options}"
    end
end
