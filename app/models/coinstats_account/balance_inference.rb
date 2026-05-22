module CoinstatsAccount::BalanceInference
  extend ActiveSupport::Concern

  def inferred_currency(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access

    if exchange_portfolio_source_for?(payload)
      preferred_exchange_currency
    elsif exchange_source_for?(payload)
      if fiat_asset?(payload)
        parse_currency(asset_metadata(payload)[:symbol]) ||
          parse_currency(payload[:currency]) ||
          family_currency ||
          "USD"
      else
        preferred_exchange_currency
      end
    elsif fiat_asset?(payload)
      parse_currency(asset_metadata(payload)[:symbol]) || parse_currency(payload[:currency]) || "USD"
    else
      parse_currency(payload[:currency]) || "USD"
    end
  end

  def inferred_current_balance(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access

    if exchange_portfolio_source_for?(payload)
      portfolio_total_value(payload)
    elsif fiat_asset?(payload)
      asset_quantity(payload).abs
    elsif exchange_source_for?(payload)
      asset_quantity(payload).abs * asset_price(payload)
    else
      explicit_balance = payload[:balance] || payload[:current_balance]
      return parse_decimal(explicit_balance) if explicit_balance.present?

      asset_quantity(payload).abs * asset_price(payload)
    end
  end

  def inferred_cash_balance
    return portfolio_cash_value if exchange_portfolio_account?

    fiat_asset? ? inferred_current_balance : 0.to_d
  end

  def asset_symbol(payload = raw_payload)
    asset_metadata(payload)[:symbol].presence || account_id.to_s.upcase
  end

  def asset_name(payload = raw_payload)
    asset_metadata(payload)[:name].presence || name
  end

  def asset_quantity(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access
    raw_quantity = payload[:count] || payload[:amount] || payload[:balance] || payload[:current_balance]
    parse_decimal(raw_quantity)
  end

  def asset_price(payload = raw_payload, currency: inferred_currency(payload))
    payload = payload.to_h.with_indifferent_access
    price_data = payload[:price]
    target_currency = parse_currency(currency) || currency || "USD"

    raw_price =
      if price_data.is_a?(Hash)
        prices = price_data.with_indifferent_access
        prices[target_currency] ||
          prices[target_currency.to_s] ||
          converted_usd_amount(prices[:USD] || prices["USD"], target_currency)
      else
        price_data || payload[:priceUsd]
      end

    parse_decimal(raw_price)
  end

  def average_buy_price(payload = raw_payload, currency: inferred_currency(payload))
    payload = payload.to_h.with_indifferent_access
    average_buy = payload[:averageBuy]
    return nil if average_buy.blank?

    average_buy_hash = average_buy.to_h.with_indifferent_access
    nested_all_time = average_buy_hash[:allTime].to_h.with_indifferent_access
    target_currency = parse_currency(currency) || currency || "USD"

    raw_cost_basis =
      average_buy_hash[target_currency] ||
      average_buy_hash[target_currency.to_s] ||
      nested_all_time[target_currency] ||
      nested_all_time[target_currency.to_s] ||
      converted_usd_amount(
        average_buy_hash[:USD] || average_buy_hash["USD"] ||
        nested_all_time[:USD] || nested_all_time["USD"],
        target_currency
      )
    return nil if raw_cost_basis.blank?

    parse_decimal(raw_cost_basis)
  end

  def portfolio_coins(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access
    Array(payload[:coins]).map { |coin| coin.with_indifferent_access }
  end

  def portfolio_fiat_coins(payload = raw_payload)
    portfolio_coins(payload).select { |coin| fiat_asset?(coin) }
  end

  def portfolio_non_fiat_coins(payload = raw_payload)
    portfolio_coins(payload).reject { |coin| fiat_asset?(coin) }
  end

  def portfolio_total_value(payload = raw_payload, currency: inferred_currency(payload))
    portfolio_coins(payload).sum { |coin| current_value_for_coin(coin, currency: currency) }
  end

  def portfolio_cash_value(payload = raw_payload, currency: inferred_currency(payload))
    portfolio_fiat_coins(payload).sum { |coin| current_value_for_coin(coin, currency: currency) }
  end

  def current_value_for_coin(coin_payload, currency: inferred_currency(coin_payload))
    coin_payload = coin_payload.to_h.with_indifferent_access

    explicit_value = coin_payload[:currentValue] || coin_payload[:current_value] || coin_payload[:totalWorth]
    if explicit_value.present?
      return extract_currency_amount(explicit_value, currency) if explicit_value.is_a?(Hash)
      return exchange_scalar_value(explicit_value, coin_payload, currency: currency) if exchange_value_payload?(coin_payload)

      return parse_decimal(explicit_value)
    end

    asset_quantity(coin_payload).abs * asset_price(coin_payload, currency: currency)
  end
end
