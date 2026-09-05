# frozen_string_literal: true

module CoinspotAccount::AudConverter
  private

    # Converts an AUD amount (all CoinSpot activity is reported in AUD) into
    # the account's target currency using the exchange rate for `date`.
    # Returns [converted_amount, approximate?, rate_date]: approximate? is
    # true when no rate exists for the exact date (rate_date nil) or the
    # nearest available rate came from a different date than requested.
    # Falls back to the raw AUD amount, flagged approximate, on any failure
    # rather than raising -- a missing FX rate shouldn't abort an import.
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
