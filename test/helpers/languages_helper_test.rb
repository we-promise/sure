require "test_helper"

class LanguagesHelperTest < ActiveSupport::TestCase
  test "folded_translations case-folds every supported locale's translation of a key" do
    folded = LanguagesHelper.folded_translations("models.category.defaults.food_and_drink")

    assert_includes folded, "food & drink"
    assert_includes folded, "restaurants & bars"
    assert folded.frozen?
  end

  test "folded_translations skips locales without a translation" do
    assert_empty LanguagesHelper.folded_translations("languages_helper_test.missing_key")
  end

  test "folded_translations is rebuilt once the current request is reset" do
    key = "languages_helper_test.stored_key"
    I18n.backend.store_translations(:en, languages_helper_test: { stored_key: "First" })
    assert_equal Set.new([ "first" ]), LanguagesHelper.folded_translations(key)

    I18n.backend.store_translations(:en, languages_helper_test: { stored_key: "Second" })
    assert_equal Set.new([ "first" ]), LanguagesHelper.folded_translations(key)

    Current.reset
    assert_equal Set.new([ "second" ]), LanguagesHelper.folded_translations(key)
  ensure
    I18n.reload!
  end
end
