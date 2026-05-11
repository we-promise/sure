# frozen_string_literal: true

module KrakenAccount::UsdConverter
  private

    def convert_from_usd(amount, date: Date.current)
      return [ amount.to_d, false, nil ] if target_currency == "USD"

      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: target_currency, date: date)
      return [ amount.to_d, true, nil ] if rate.nil?

      converted = Money.new(amount, "USD").exchange_to(target_currency, custom_rate: rate.rate).amount
      stale = rate.date != date
      rate_date = stale ? rate.date : nil

      [ converted, stale, rate_date ]
    end

    def build_stale_extra(stale, rate_date, target_date)
      kraken_meta = if stale
        {
          "stale_rate" => true,
          "rate_date_used" => rate_date&.to_s,
          "rate_target_date" => target_date&.to_s
        }
      else
        { "stale_rate" => false }
      end

      { "kraken" => kraken_meta }
    end
end
