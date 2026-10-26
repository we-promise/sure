require "test_helper"

class LanguagesHelperTest < ActionView::TestCase
  include LanguagesHelper

  test "JavaScript plural locale follows the actual translated dictionary" do
    I18n.with_locale(:ru) do
      assert_equal :ru, translation_locale("javascript.attachment_upload.upload_files")
    end
    I18n.with_locale(:de) do
      assert_equal :en, translation_locale("javascript.attachment_upload.upload_files")
      assert_equal :de, translation_locale("settings.preferences.show.selected_currencies_count")
    end
  end

  test "Russian preference labels preserve canonical option values" do
    I18n.with_locale(:ru) do
      assert_includes language_options, [ "Русский (ru)", :ru ]
      assert_includes country_options, [ "🇷🇺 Российская Федерация", "RU" ]
      assert_includes country_options, [ "🇽🇰 Косово", "XK" ]
      assert_equal LanguagesHelper::COUNTRY_MAPPING.size, country_options.size
      assert_equal LanguagesHelper::COUNTRY_MAPPING.keys.map(&:to_s).sort, country_options.map(&:last).sort
      supported_locales = I18n.available_locales.select { |locale| LanguagesHelper::SUPPORTED_LOCALES.include?(locale.to_s) }
      assert_equal supported_locales.sort_by(&:to_s), language_options.map(&:last).sort_by(&:to_s)
      assert_equal ActiveSupport::TimeZone.all.map { |zone| zone.tzinfo.identifier }, timezone_options.map(&:last)
      assert_includes timezone_options, [ "(+03:00) Москва", "Europe/Moscow" ]
    end
  end
end
