# frozen_string_literal: true

module PluggyAccount::Investments::DataHelpers
  def resolve_security(symbol, symbol_data = {})
    ticker = symbol.to_s.upcase.strip
    return nil if ticker.blank?

    security = Security.find_by(ticker: ticker)
    return security if security

    Security.create!(
      ticker: ticker,
      name: extract_security_name(symbol_data, ticker),
      exchange_mic: extract_exchange(symbol_data),
      country_code: extract_country_code(symbol_data)
    )
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    Security.find_by(ticker: ticker)
  end

  def extract_security_name(symbol_data, fallback_ticker)
    symbol_data = symbol_data.with_indifferent_access if symbol_data.respond_to?(:with_indifferent_access)
    name = symbol_data[:name] || symbol_data[:description] || fallback_ticker
    name = fallback_ticker if name.is_a?(Hash) || name.blank?
    name = name.titleize if name == name.upcase && name.length > 4
    name
  end

  def extract_exchange(symbol_data)
    symbol_data = symbol_data.with_indifferent_access if symbol_data.respond_to?(:with_indifferent_access)
    exchange = symbol_data[:exchange]
    return nil unless exchange.is_a?(Hash)
    exchange.with_indifferent_access[:mic_code] || exchange.with_indifferent_access[:id]
  end

  def extract_country_code(symbol_data)
    symbol_data = symbol_data.with_indifferent_access if symbol_data.respond_to?(:with_indifferent_access)
    currency = symbol_data[:currency]
    currency = currency[:code] if currency.is_a?(Hash)
    { "USD" => "US", "CAD" => "CA", "BRL" => "BR" }.fetch(currency, nil)
  end
end
