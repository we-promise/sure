module CoinstatsAccount::ValueHelpers
  extend ActiveSupport::Concern

  private
    def family_currency
      parse_currency(coinstats_item&.family&.currency)
    end

    def preferred_exchange_currency
      family_currency.presence || "USD"
    end

    def exchange_rate_available?(from:, to:)
      return true if from == to

      ExchangeRate.find_or_fetch_rate(from: from, to: to, date: Date.current).present?
    rescue StandardError => e
      Rails.logger.warn("CoinstatsAccount #{id} - Failed to load FX #{from}/#{to}: #{e.class} - #{e.message}")
      false
    end

    def converted_usd_amount(raw_usd_amount, target_currency)
      return raw_usd_amount if raw_usd_amount.blank?
      return raw_usd_amount if target_currency == "USD"

      usd_amount = parse_decimal(raw_usd_amount)
      return if usd_amount.zero? && raw_usd_amount.to_s != "0"

      return unless exchange_rate_available?(from: "USD", to: target_currency)

      Money.new(usd_amount, "USD").exchange_to(target_currency).amount
    rescue StandardError => e
      Rails.logger.warn("CoinstatsAccount #{id} - Failed to convert USD -> #{target_currency}: #{e.class} - #{e.message}")
      nil
    end

    def asset_metadata(payload)
      payload = payload.to_h.with_indifferent_access
      metadata = payload[:coin]
      metadata.is_a?(Hash) ? metadata.with_indifferent_access : payload
    end

    def extract_currency_amount(value, currency)
      return parse_decimal(value) unless value.is_a?(Hash)

      values = value.with_indifferent_access
      target_currency = parse_currency(currency) || currency || "USD"

      parse_decimal(
        values[target_currency] ||
        values[target_currency.to_s] ||
        converted_usd_amount(values[:USD] || values["USD"], target_currency)
      )
    end

    def exchange_value_payload?(payload)
      exchange_source_for?(payload) || exchange_portfolio_source_for?(payload)
    end

    def exchange_scalar_value(explicit_value, coin_payload, currency:)
      target_currency = parse_currency(currency) || currency || "USD"
      return parse_decimal(explicit_value) if target_currency == "USD"

      price_based_value = asset_quantity(coin_payload).abs * asset_price(coin_payload, currency: target_currency)
      return price_based_value if price_based_value.positive?

      converted_value = converted_usd_amount(explicit_value, target_currency)
      return parse_decimal(converted_value) if converted_value.present?

      parse_decimal(explicit_value)
    end

    def fiat_identifier?(value)
      value.to_s.start_with?("FiatCoin")
    end

    def parse_decimal(value)
      return 0.to_d if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      0.to_d
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for CoinstatsAccount #{id}, defaulting to USD")
    end
end
