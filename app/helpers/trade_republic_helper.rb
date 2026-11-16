module TradeRepublicHelper
  # "Login expires in about 5 hours (16 Oct 18:45)." Where the sentence has no
  # translation it falls back to English, and so do its time words, so the
  # sentence never mixes two languages.
  def trade_republic_session_expiry(key, expires_at)
    locale = I18n.t(key, default: nil, fallback: false) ? I18n.locale : I18n.default_locale
    I18n.with_locale(locale) do
      t(key, time: distance_of_time_in_words_to_now(expires_at), at: l(expires_at, format: :short))
    end
  end
end
