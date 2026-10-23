require "test_helper"

class LanguagesHelperTest < ActionView::TestCase
  include LanguagesHelper

  test "Russian preference labels preserve canonical option values" do
    I18n.with_locale(:ru) do
      assert_includes language_options, [ "Русский (ru)", :ru ]
      assert_includes country_options, [ "🇷🇺 Российская Федерация", "RU" ]
      assert_includes country_options, [ "🇽🇰 Косово", "XK" ]
      assert_equal LanguagesHelper::COUNTRY_MAPPING.size, country_options.size
      assert_includes timezone_options, [ "(+03:00) Москва", "Europe/Moscow" ]
    end
  end
end
