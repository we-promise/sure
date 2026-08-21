require "test_helper"

class LocaleNumberTest < ActiveSupport::TestCase
  test "parses comma decimals" do
    assert_equal BigDecimal("2.65"), LocaleNumber.parse("2,65")
    assert_equal BigDecimal("-2.5"), LocaleNumber.parse("-2,5")
  end

  test "parses period decimals" do
    assert_equal BigDecimal("2.65"), LocaleNumber.parse("2.65")
  end

  test "parses european thousands with comma decimal" do
    assert_equal BigDecimal("1234.56"), LocaleNumber.parse("1.234,56")
  end

  test "parses us thousands with period decimal" do
    assert_equal BigDecimal("1234.56"), LocaleNumber.parse("1,234.56")
  end

  test "passes numerics through" do
    assert_equal 2.65, LocaleNumber.parse(2.65)
  end

  test "formats with locale separator" do
    I18n.with_locale(:da) do
      assert_equal "2,65", LocaleNumber.format(2.65)
    end

    I18n.with_locale(:en) do
      assert_equal "2.65", LocaleNumber.format(2.65)
    end
  end
end
