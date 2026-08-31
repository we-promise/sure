# frozen_string_literal: true

module CoinspotAccount::AudConverter
  private

    def convert_from_aud(amount, date:)
      amount = amount.to_d
      target = target_currency.presence || "AUD"
      return [ amount, false, date ] if target == "AUD"

      rate = ExchangeRate.find_or_fetch_rate(from: "AUD", to: target, date: date)
      return [ amount, true, nil ] unless rate

      [ amount * rate.rate.to_d, rate.date != date, rate.date ]
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "AUD conversion failed: #{e.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_account.coinspot_item&.family,
        metadata: { date: date.to_s, target_currency: target_currency, error_class: e.class.name }
      )
      [ amount, true, nil ]
    end
end
