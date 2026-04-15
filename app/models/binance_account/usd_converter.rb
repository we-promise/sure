# frozen_string_literal: true

# Shared currency conversion helpers for Binance processors.
# Converts USD amounts to the family's configured base currency using
# ExchangeRate.find_or_fetch_rate (which has a built-in 5-day nearest-rate lookback).
# When a fallback or no rate is used, sets a stale flag in account.extra["binance"].
module BinanceAccount::UsdConverter
  private

    # Converts a USD amount to target_currency on the given date.
    # @return [Array(BigDecimal, Boolean, Date|nil)]
    #   [converted_amount, stale, rate_date_used]
    #   stale is false when the exact date rate was found, true otherwise.
    #   rate_date_used is nil when exact rate was used or no rate found.
    def convert_from_usd(amount, date: Date.current)
      return [ amount, false, nil ] if target_currency == "USD"

      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: target_currency, date: date)

      if rate.nil?
        return [ amount.to_d, true, nil ]
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
