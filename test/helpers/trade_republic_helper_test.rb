require "test_helper"

class TradeRepublicHelperTest < ActionView::TestCase
  KEY = "settings.providers.trade_republic_panel.session_expires_in".freeze

  test "the expiry shows how long the login lasts and when it ends" do
    expires_at = 5.hours.from_now

    assert_equal "Login expires in about 5 hours (#{I18n.l(expires_at, format: :short)}).",
                 trade_republic_session_expiry(KEY, expires_at)
  end

  test "the expiry is written in the language of the sentence" do
    I18n.backend.store_translations(:nl, settings: { providers: { trade_republic_panel: { session_expires_in: "Login verloopt over %{time} (%{at})." } } })
    expires_at = 5.hours.from_now

    text = I18n.with_locale(:nl) { trade_republic_session_expiry(KEY, expires_at) }

    assert_equal "Login verloopt over ongeveer 5 uur (#{I18n.l(expires_at, format: :short, locale: :nl)}).", text
  ensure
    I18n.reload!
  end

  test "an untranslated sentence keeps its time words in English" do
    expires_at = 5.hours.from_now
    key = "settings.providers.trade_republic_panel.only_in_english_for_this_test"
    I18n.backend.store_translations(:en, settings: { providers: { trade_republic_panel: { only_in_english_for_this_test: "Login expires in %{time} (%{at})." } } })

    text = I18n.with_locale(:nl) { trade_republic_session_expiry(key, expires_at) }

    assert_equal "Login expires in about 5 hours (#{I18n.l(expires_at, format: :short, locale: :en)}).", text
  ensure
    I18n.reload!
  end
end
