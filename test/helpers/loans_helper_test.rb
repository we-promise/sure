require "test_helper"

class LoansHelperTest < ActionView::TestCase
  include LoansHelper

  test "every day-count convention the engine offers has a label" do
    options = loan_day_count_convention_options

    assert_equal Loan::DAY_COUNT_CONVENTIONS.length, options.length
    options.each do |label, value|
      assert_includes Loan::DAY_COUNT_CONVENTIONS, value
      assert label.present?, "#{value} has no label"
      assert_no_match(/translation missing/, label)
    end
  end

  # The helper is built from the model constant precisely so a convention the
  # engine gains cannot be offered without a label. That promise rests on
  # `raise: true`: `raise_on_missing_translations` is not enabled in
  # development or test, and `config.i18n.fallbacks` is on, so without it a
  # missing key renders the English label or the literal "translation missing"
  # string and the form ships a nonsense option instead of failing.
  test "a convention with no label fails loudly rather than rendering a fallback" do
    original = Loan::DAY_COUNT_CONVENTIONS
    Loan.send(:remove_const, :DAY_COUNT_CONVENTIONS)
    Loan.const_set(:DAY_COUNT_CONVENTIONS, original + [ "convention_with_no_label" ])

    assert_raises(I18n::MissingTranslationData) { loan_day_count_convention_options }
  ensure
    Loan.send(:remove_const, :DAY_COUNT_CONVENTIONS)
    Loan.const_set(:DAY_COUNT_CONVENTIONS, original)
  end

  # `raise: true` must not turn a missing TRANSLATION into a failure: only en
  # and de carry these labels, and a Spanish user editing a loan must get the
  # English labels through the configured fallbacks, not an error page. The
  # raise is for a key missing in every locale, which the test above covers.
  test "a locale without its own labels falls back to English rather than failing" do
    key = "loans.form.day_count_convention_actual_365"
    assert_nil I18n.t(key, locale: :es, fallback: false, default: nil),
               "the precondition is a locale that does not carry the label itself"

    english = I18n.with_locale(:en) { loan_day_count_convention_options }
    spanish = I18n.with_locale(:es) { loan_day_count_convention_options }

    assert_equal english, spanish
  end
end
