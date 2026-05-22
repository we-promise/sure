require "test_helper"
require "securerandom"

class PolishPluralizationTest < ActiveSupport::TestCase
  test "uses rails i18n plural rules for polish" do
    translation_key = "test_pluralization_#{SecureRandom.hex(6)}"

    I18n.backend.store_translations(:pl, translation_key => {
      sample: {
        one: "one",
        few: "few",
        many: "many",
        other: "other"
      }
    })

    path = "#{translation_key}.sample"

    assert_equal "many", I18n.t(path, locale: :pl, count: 0)
    assert_equal "one", I18n.t(path, locale: :pl, count: 1)
    assert_equal "few", I18n.t(path, locale: :pl, count: 2)
    assert_equal "many", I18n.t(path, locale: :pl, count: 5)
    assert_equal "many", I18n.t(path, locale: :pl, count: 12)
    assert_equal "few", I18n.t(path, locale: :pl, count: 22)
    assert_equal "many", I18n.t(path, locale: :pl, count: 25)
  end
end
