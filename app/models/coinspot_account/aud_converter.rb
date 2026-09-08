# frozen_string_literal: true

module CoinspotAccount::AudConverter
  class ConversionUnavailableError < StandardError; end

  private

    # Converts an AUD amount (all CoinSpot activity is reported in AUD) into
    # the account's target currency using the exchange rate for `date`.
    # Returns [converted_amount, approximate?, rate_date]: approximate? is
    # true when the nearest available rate came from a different date than
    # requested. Raises when a non-AUD amount cannot be converted. Persisting the raw AUD
    # number with a different currency would corrupt the account valuation.
    def convert_from_aud(amount, date:)
      amount = amount.to_d
      target = target_currency.presence || "AUD"
      return [ amount, false, date ] if target == "AUD"

      rate = ExchangeRate.find_or_fetch_rate(from: "AUD", to: target, date: date)
      raise ConversionUnavailableError, "No AUD-#{target} exchange rate for #{date}" unless rate

      [ amount * rate.rate.to_d, rate.date != date, rate.date ]
    rescue ConversionUnavailableError => e
      capture_conversion_failure(amount, date, target, e)
      raise
    rescue StandardError => e
      capture_conversion_failure(amount, date, target, e)
      raise ConversionUnavailableError, "AUD conversion failed: #{e.message}"
    end

    def capture_conversion_failure(amount, date, target, error)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "AUD conversion unavailable for #{target}: #{error.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_account.coinspot_item&.family,
        account_provider: coinspot_account.account_provider,
        metadata: {
          amount: amount.to_s("F"),
          date: date.to_s,
          target_currency: target,
          error_class: error.class.name
        }
      )
    end
end
