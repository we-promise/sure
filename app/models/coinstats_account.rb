# Represents a CoinStats-backed synced account.
# This may be a wallet-scoped asset row or a consolidated exchange portfolio.
class CoinstatsAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :coinstats_item

  # Association through account_providers (standard pattern for all providers)
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: [ :coinstats_item_id, :wallet_address ], allow_nil: true }

  # Alias for compatibility with provider adapter pattern
  alias_method :current_account, :account

  # Updates account with latest balance data from CoinStats API.
  # @param account_snapshot [Hash] Normalized balance data from API
  def upsert_coinstats_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Build attributes to update
    attrs = {
      current_balance: snapshot[:balance] || snapshot[:current_balance] || inferred_current_balance(snapshot),
      currency: inferred_currency(snapshot) || parse_currency(snapshot[:currency]) || "USD",
      name: snapshot[:name],
      account_status: snapshot[:status],
      provider: snapshot[:provider],
      institution_metadata: {
        logo: snapshot[:institution_logo]
      }.compact,
      raw_payload: account_snapshot
    }

    # Only set account_id if provided and not already set (preserves ID from initial creation)
    if snapshot[:id].present? && account_id.blank?
      attrs[:account_id] = snapshot[:id].to_s
    end

    update!(attrs)
  end

  # Stores transaction data from CoinStats API for later processing.
  # @param transactions_snapshot [Hash, Array] Raw transactions response or array
  def upsert_coinstats_transactions_snapshot!(transactions_snapshot)
    # CoinStats API returns: { meta: { page, limit }, result: [...] }
    # Extract just the result array for storage, or use directly if already an array
    transactions_array = if transactions_snapshot.is_a?(Hash)
      snapshot = transactions_snapshot.with_indifferent_access
      snapshot[:result] || []
    elsif transactions_snapshot.is_a?(Array)
      transactions_snapshot
    else
      []
    end

    assign_attributes(
      raw_transactions_payload: transactions_array
    )

    save!
  end

  def wallet_source?
    payload = raw_payload.to_h.with_indifferent_access
    payload[:source] == "wallet" || (payload[:address].present? && payload[:blockchain].present?)
  end

  def exchange_source?
    exchange_source_for?(raw_payload)
  end

  def exchange_portfolio_account?
    payload = raw_payload.to_h.with_indifferent_access
    exchange_source_for?(payload) && (
      ActiveModel::Type::Boolean.new.cast(payload[:portfolio_account]) ||
      payload[:coins].is_a?(Array)
    )
  end

  def legacy_exchange_asset_account?
    exchange_source? && !exchange_portfolio_account?
  end

  def fiat_asset?(payload = raw_payload)
    payload = payload.to_h.with_indifferent_access
    return false if exchange_portfolio_source_for?(payload)

    metadata = asset_metadata(payload)

    ActiveModel::Type::Boolean.new.cast(metadata[:isFiat]) ||
      ActiveModel::Type::Boolean.new.cast(payload[:isFiat]) ||
      fiat_identifier?(metadata[:identifier]) ||
      fiat_identifier?(payload[:coinId]) ||
      fiat_identifier?(account_id)
  end

  def crypto_asset?
    !fiat_asset?
  end

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

  private
    def exchange_source_for?(payload)
      payload = payload.to_h.with_indifferent_access
      payload[:source] == "exchange" || payload[:portfolio_id].present?
    end

    def exchange_portfolio_source_for?(payload)
      payload = payload.to_h.with_indifferent_access
      exchange_source_for?(payload) && (
        ActiveModel::Type::Boolean.new.cast(payload[:portfolio_account]) ||
        payload[:coins].is_a?(Array)
      )
    end

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
