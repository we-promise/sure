require "test_helper"
require "securerandom"

class CatalanPluralizationTest < ActiveSupport::TestCase
  test "uses rails i18n plural rules for catalan" do
    translation_key = "test_pluralization_#{SecureRandom.hex(6)}"

    I18n.backend.store_translations(:ca, translation_key => {
      sample: {
        one: "one",
        other: "other"
      }
    })

    path = "#{translation_key}.sample"

    assert_equal "other", I18n.t(path, locale: :ca, count: 0)
    assert_equal "one", I18n.t(path, locale: :ca, count: 1)
    assert_equal "other", I18n.t(path, locale: :ca, count: 2)
    assert_equal "other", I18n.t(path, locale: :ca, count: 5)
    assert_equal "other", I18n.t(path, locale: :ca, count: 100)
  end
end
