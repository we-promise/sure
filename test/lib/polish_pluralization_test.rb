require "test_helper"

class PolishPluralizationTest < ActiveSupport::TestCase
  test "uses rails i18n plural rules for polish" do
    I18n.backend.store_translations(:pl, test_pluralization: {
      sample: {
        one: "one",
        few: "few",
        many: "many",
        other: "other"
      }
    })

    assert_equal "many", I18n.t("test_pluralization.sample", locale: :pl, count: 0)
    assert_equal "one", I18n.t("test_pluralization.sample", locale: :pl, count: 1)
    assert_equal "few", I18n.t("test_pluralization.sample", locale: :pl, count: 2)
    assert_equal "many", I18n.t("test_pluralization.sample", locale: :pl, count: 5)
    assert_equal "many", I18n.t("test_pluralization.sample", locale: :pl, count: 12)
    assert_equal "few", I18n.t("test_pluralization.sample", locale: :pl, count: 22)
    assert_equal "many", I18n.t("test_pluralization.sample", locale: :pl, count: 25)
  end
end
