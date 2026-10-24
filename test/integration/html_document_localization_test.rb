require "test_helper"

class HtmlDocumentLocalizationTest < ActionDispatch::IntegrationTest
  setup { ensure_tailwind_build }

  LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
    test "#{locale} login page declares its request language without updating user preferences" do
      initial_locale = I18n.locale
      preferences = User.order(:id).pluck(:id, :locale, :updated_at)

      assert_no_difference [ "User.count", "Family.count", "Session.count" ] do
        get new_session_path, params: { locale: locale }
      end

      assert_response :success
      assert_select "html[lang=?]", locale, count: 1
      assert_select "a[href=?]", new_session_path, text: I18n.t("layouts.auth.sign_in", locale: locale, fallback: false, raise: true)
      assert_equal preferences, User.order(:id).pluck(:id, :locale, :updated_at)
      assert_equal initial_locale, I18n.locale
    end
  end
end
