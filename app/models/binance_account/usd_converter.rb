# frozen_string_literal: true

# Shared currency conversion helpers for Binance processors.
# Converts USD amounts to the linked account currency using
# ExchangeRate.find_or_fetch_rate (which has a built-in 5-day nearest-rate lookback).
# A nearest-date rate is marked stale; a missing rate must not relabel USD.
module BinanceAccount::UsdConverter
  private

    # Converts a USD amount to target_currency on the given date.
    # @return [Array(BigDecimal, Boolean, Date|nil)]
    #   [converted_amount, stale, rate_date_used]
    #   stale is false when the exact date rate was found, true otherwise.
    #   rate_date_used is nil when the exact rate was used.
    def convert_from_usd(amount, date: Date.current)
      return [ 0.to_d, false, nil ] if amount.to_d.zero?
      return [ amount, false, nil ] if target_currency == "USD"

      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: target_currency, date: date)

      if rate.nil?
        raise Money::ConversionError.new(from_currency: "USD", to_currency: target_currency, date: date)
      end

      converted = Money.new(amount, "USD").exchange_to(target_currency, custom_rate: rate.rate).amount
      stale     = rate.date != date
      rate_date = stale ? rate.date : nil

      [ converted, stale, rate_date ]
    end

    # Builds the hash to deep-merge into account.extra.
    def build_stale_extra(stale, rate_date, target_date)
      binance_meta = if stale
        {
          "stale_rate"       => true,
          "rate_date_used"   => rate_date&.to_s,
          "rate_target_date" => target_date.to_s
        }
      else
        { "stale_rate" => false }
      end

      { "binance" => binance_meta }
    end
end
