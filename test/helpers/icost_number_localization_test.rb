require "test_helper"

class IcostNumberLocalizationTest < ActionView::TestCase
  include IcostImportsHelper

  test "structured decimals use locale separators without losing precision" do
    value = BigDecimal("1234567890123.1234")
    I18n.with_locale(:en) { assert_equal "1,234,567,890,123.1234", icost_value(value) }
    I18n.with_locale(:de) { assert_equal "1.234.567.890.123,1234", icost_value(value) }
    I18n.with_locale(:"zh-CN") { assert_equal "1,234,567,890,123.1234", icost_value(value) }
  end

  test "source strings stay unchanged even when they look like dates or numbers" do
    I18n.with_locale(:de) do
      assert_equal "1234.56", icost_value("1234.56")
      assert_equal "2026/01/02 03:04:05", icost_value("2026/01/02 03:04:05")
      assert_equal "用户分类和备注", icost_value("用户分类和备注")
    end
  end

  test "review timestamps and number formats exist for every selectable locale" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      assert I18n.l(Time.utc(2026, 1, 2, 3, 4, 5), format: :long, locale: locale).present?
      assert I18n.t("number.format.separator", locale: locale, fallback: false, raise: true).present?
    end
  end
end
