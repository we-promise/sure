require "bigdecimal"
require "date"
require "time"

class ScalableItem::PortfolioNormalizer
  MAX_OBSERVATION_AGE = 72.hours
  MAX_FUTURE_SKEW = 5.minutes
  CURRENCY_PATTERN = /\A[A-Z]{3}\z/
  ISIN_PATTERN = /\A[A-Z]{2}[A-Z0-9]{9}[0-9]\z/
  MAX_NAME_BYTES = 512
  ROUNDING_TOLERANCE = BigDecimal("0.01")

  Position = Data.define(
    :isin,
    :name,
    :security_type,
    :quantity,
    :valuation,
    :currency,
    :unit_price,
    :fifo_price,
    :quote_metadata
  )

  BrokerPortfolio = Data.define(
    :uid,
    :name,
    :currency,
    :cash_balance,
    :securities_valuation,
    :portfolio_valuation,
    :crypto_valuation,
    :current_balance,
    :observed_at,
    :valuation_timestamp,
    :inventory_updated_at,
    :positions,
    :raw_metadata
  )

  Snapshot = Data.define(
    :person_identity,
    :connection_generation,
    :account_id,
    :fetched_at,
    :observed_at,
    :accounts
  )

  def initialize(now: Time.current)
    @now = now
  end

  def normalize(discovery:, portfolio_responses:, person_identity:, connection_generation:, fetched_at: @now)
    invalid_snapshot! unless fetched_at.respond_to?(:to_time)
    fetched_at = fetched_at.to_time.utc
    account = required_hash(discovery["account"], "account")
    account_id = required_string(account["id"], "account.id")
    portfolio_rows = required_array(account["brokerPortfolios"], "account.brokerPortfolios")
    ids = portfolio_rows.map do |row|
      required_string(required_hash(row, "broker portfolio")["id"], "broker portfolio.id")
    end
    invalid_snapshot! if ids.empty? || ids.uniq.length != ids.length

    person_identity = required_string(person_identity, "person_identity")
    connection_generation = Integer(connection_generation)
    responses = normalize_portfolio_responses(portfolio_responses, ids)
    accounts = ids.map do |uid|
      normalize_portfolio(
        uid,
        responses.fetch(uid),
        account_id: account_id,
        person_identity: person_identity,
        fetched_at: fetched_at
      )
    end
    observed_at = accounts.map(&:observed_at).min

    Snapshot.new(
      person_identity: person_identity,
      connection_generation: connection_generation,
      account_id: account_id,
      fetched_at: fetched_at,
      observed_at: observed_at,
      accounts: accounts.freeze
    )
  rescue Provider::Scalable::Error
    raise
  rescue ArgumentError, KeyError, TypeError, Date::Error
    invalid_snapshot!
  end

  def self.valid_isin?(value)
    isin = value.to_s.upcase
    return false unless isin.match?(ISIN_PATTERN)

    expanded = isin.chars.flat_map do |character|
      character.match?(/[A-Z]/) ? (character.ord - 55).to_s.chars : [ character ]
    end
    checksum = expanded.reverse.each_with_index.sum do |digit, index|
      value = digit.to_i
      value *= 2 if index.odd?
      value -= 9 if value > 9
      value
    end

    (checksum % 10).zero?
  end

  private

    def normalize_portfolio_responses(portfolio_responses, ids)
      rows = required_array(portfolio_responses, "portfolio responses")
      by_id = {}
      rows.each do |row|
        data = required_hash(row, "portfolio response")
        uid = required_string(data["portfolio_id"], "portfolio_id")
        invalid_snapshot! unless ids.include?(uid) && !by_id.key?(uid)
        by_id[uid] = data
      end
      invalid_snapshot! unless by_id.keys.sort == ids.sort

      by_id
    end

    def normalize_portfolio(uid, response, account_id:, person_identity:, fetched_at:)
      overview = required_hash(response["overview"], "overview response")
      cash_breakdown = required_hash(response["cash_breakdown"], "cash breakdown response")
      holdings = required_hash(response["holdings"], "holdings response")
      validate_portfolio_response!(overview, account_id, uid)
      validate_portfolio_response!(cash_breakdown, account_id, uid)
      validate_portfolio_response!(holdings, account_id, uid)

      raw_valuation = overview.dig("account", "brokerPortfolio", "valuation")
      valuation = required_hash(raw_valuation, "account.brokerPortfolio.valuation")
      valuation_timestamp = timestamp(valuation["timestampUtc"], "valuation.timestampUtc")
      inventory_updated_at = optional_timestamp(
        valuation["lastInventoryUpdateTimestampUtc"],
        "valuation.lastInventoryUpdateTimestampUtc"
      )
      validate_freshness!(valuation_timestamp, fetched_at)
      invalid_snapshot! if inventory_updated_at && inventory_updated_at > fetched_at + MAX_FUTURE_SKEW

      cash = required_hash(cash_breakdown.dig("account", "brokerPortfolio", "payments", "buyingPower"),
        "account.brokerPortfolio.payments.buyingPower")
      cash_balance = decimal(cash["cashBalance"], "cashBalance").round(4)
      loaned = non_negative_decimal(cash["loaned"], "loaned")
      securities_valuation = non_negative_decimal(valuation["securitiesValuation"], "securitiesValuation").round(4)
      portfolio_valuation = non_negative_decimal(valuation["valuation"], "valuation").round(4)
      crypto_valuation = valuation["cryptoValuation"].nil? ? BigDecimal("0") :
        non_negative_decimal(valuation["cryptoValuation"], "cryptoValuation").round(4)
      raise Provider::Scalable::Error.new(:unsupported_account) unless crypto_valuation.zero?
      raise Provider::Scalable::Error.new(:unsupported_account) unless loaned.zero?
      invalid_snapshot! unless fits_database_decimal?(cash_balance, precision: 19, scale: 4)
      invalid_snapshot! unless fits_database_decimal?(securities_valuation, precision: 19, scale: 4)
      invalid_snapshot! unless fits_database_decimal?(portfolio_valuation, precision: 19, scale: 4)

      items = required_array(
        holdings.dig("account", "brokerPortfolio", "inventory", "items"),
        "account.brokerPortfolio.inventory.items"
      )
      positions = normalize_positions(items)
      holdings_total = positions.sum(BigDecimal("0"), &:valuation)
      invalid_snapshot! unless close_enough?(holdings_total, securities_valuation)

      matches_securities = close_enough?(portfolio_valuation, holdings_total)
      matches_with_cash = close_enough?(portfolio_valuation, holdings_total + cash_balance)
      coherent_valuation = matches_securities || matches_with_cash
      invalid_snapshot! unless coherent_valuation

      current_balance = (holdings_total + cash_balance).round(4)
      invalid_snapshot! unless fits_database_decimal?(current_balance, precision: 19, scale: 4)

      BrokerPortfolio.new(
        uid: uid,
        name: ScalableAccount::BROKER_NAME,
        currency: ScalableAccount::BROKER_CURRENCY,
        cash_balance: cash_balance,
        securities_valuation: securities_valuation,
        portfolio_valuation: portfolio_valuation,
        crypto_valuation: crypto_valuation,
        current_balance: current_balance,
        observed_at: fetched_at,
        valuation_timestamp: valuation_timestamp,
        inventory_updated_at: inventory_updated_at,
        positions: positions.freeze,
        raw_metadata: {
          "portfolio_id" => uid,
          "account_id" => account_id,
          "person_identity" => person_identity,
          "valuation" => portfolio_valuation.to_s("F"),
          "securities_valuation" => securities_valuation.to_s("F"),
          "cash_balance" => cash_balance.to_s("F"),
          "crypto_valuation" => crypto_valuation.to_s("F"),
          "valuation_timestamp" => valuation_timestamp.utc.iso8601,
          "observed_at" => fetched_at.utc.iso8601,
          "inventory_updated_at" => inventory_updated_at&.utc&.iso8601,
          "fetched_at" => fetched_at.utc.iso8601,
          "positions" => positions.map do |position|
            {
              "isin" => position.isin,
              "name" => position.name,
              "security_type" => position.security_type,
              "quantity" => position.quantity.to_s("F"),
              "valuation" => position.valuation.to_s("F"),
              "currency" => position.currency,
              "unit_price" => position.unit_price.to_s("F"),
              "fifo_price" => position.fifo_price&.to_s("F"),
              "quote" => position.quote_metadata
            }.compact
          end
        }.compact.freeze
      )
    end

    def validate_portfolio_response!(response, account_id, portfolio_id)
      actual = required_string(response.dig("account", "id"), "account.id")
      invalid_snapshot! unless actual == account_id
      actual_portfolio_id = required_string(
        response.dig("account", "brokerPortfolio", "id"),
        "account.brokerPortfolio.id"
      )
      invalid_snapshot! unless actual_portfolio_id == portfolio_id
    end

    def normalize_positions(items)
      positions = items.filter_map { |item| normalize_position(item) }
      invalid_snapshot! unless positions.map(&:isin).uniq.length == positions.length

      positions.sort_by(&:isin)
    end

    def normalize_position(raw)
      item = required_hash(raw, "inventory item")
      isin = required_string(item["isin"], "inventory item.isin").upcase
      invalid_snapshot! unless self.class.valid_isin?(isin)
      name = required_string(item["name"], "inventory item.name")
      invalid_snapshot! if name.bytesize > MAX_NAME_BYTES || name.match?(/[\u0000-\u001F\u007F]/)
      security_type = required_string(item["type"], "inventory item.type")
      invalid_snapshot! if security_type.bytesize > 64

      position = required_hash(item.dig("inventory", "position"), "inventory item.inventory.position")
      quantity = non_negative_decimal(position["filled"], "inventory item.inventory.position.filled")
      quantity = quantity.round(18)
      value = required_hash(item["portfolioIsinPerformance"], "inventory item.portfolioIsinPerformance")
      currency = required_string(value["currency"], "portfolioIsinPerformance.currency").upcase
      raise Provider::Scalable::Error.new(:unsupported_account) unless currency.match?(CURRENCY_PATTERN) && currency == ScalableAccount::BROKER_CURRENCY

      valuation = non_negative_decimal(value["valuation"], "portfolioIsinPerformance.valuation").round(4)
      invalid_snapshot! if quantity.zero? && !valuation.zero?
      return if quantity.zero?
      invalid_snapshot! unless fits_database_decimal?(quantity, precision: 34, scale: 18)
      invalid_snapshot! unless fits_database_decimal?(valuation, precision: 19, scale: 4)
      unit_price = valuation / quantity
      invalid_snapshot! unless fits_database_decimal?(unit_price, precision: 19, scale: 4)

      quote_metadata = normalize_quote(item["quoteTick"], currency)
      fifo_price = optional_decimal(position["fifoPrice"], "inventory item.inventory.position.fifoPrice")

      Position.new(
        isin: isin,
        name: name,
        security_type: security_type,
        quantity: quantity,
        valuation: valuation,
        currency: currency,
        unit_price: unit_price,
        fifo_price: fifo_price,
        quote_metadata: quote_metadata
      )
    end

    def normalize_quote(raw, valuation_currency)
      return {} if raw.nil?
      quote = required_hash(raw, "quoteTick")
      return {} unless quote["isOutdated"] == false

      currency = optional_string(quote["currency"])
      return {} unless currency == valuation_currency
      price = optional_decimal(quote["midPrice"], "quoteTick.midPrice")
      return {} unless price&.positive?

      timestamp = optional_timestamp(quote["timestampUtc"], "quoteTick.timestampUtc")
      return {} unless timestamp && timestamp <= @now + MAX_FUTURE_SKEW && timestamp >= @now - MAX_OBSERVATION_AGE

      { "mid_price" => price.to_s("F"), "currency" => currency, "timestamp" => timestamp.utc.iso8601 }.freeze
    end

    def validate_freshness!(observed_at, fetched_at)
      invalid_snapshot! if observed_at > fetched_at + MAX_FUTURE_SKEW
      raise Provider::Scalable::Error.new(:stale_snapshot) if observed_at < fetched_at - MAX_OBSERVATION_AGE
    end

    def required_hash(value, path)
      value.is_a?(Hash) ? value : invalid_snapshot!(path)
    end

    def required_array(value, path)
      value.is_a?(Array) ? value : invalid_snapshot!(path)
    end

    def required_string(value, path)
      string = value.to_s.strip
      invalid_snapshot!(path) if value.nil? || string.empty? || string.bytesize > 512 || string.match?(/[\u0000-\u001F\u007F]/)

      string
    end

    def optional_string(value)
      return if value.nil?

      string = value.to_s.strip
      string if !string.empty? && string.bytesize <= 512 && !string.match?(/[\u0000-\u001F\u007F]/)
    end

    def timestamp(raw, path)
      time = optional_timestamp(raw, path)
      invalid_snapshot!(path) unless time

      time
    end

    def optional_timestamp(raw, path)
      return if raw.nil?
      value = raw.is_a?(Hash) ? raw["time"] : raw
      return if value.nil?

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      invalid_snapshot!(path)
    end

    def decimal(raw, path)
      value = if raw.is_a?(BigDecimal)
        raw
      elsif raw.is_a?(Numeric)
        BigDecimal(raw.to_s)
      elsif raw.is_a?(String) && raw.strip.bytesize <= 128
        BigDecimal(raw.strip)
      else
        invalid_snapshot!(path)
      end
      invalid_snapshot!(path) unless value.finite?

      value
    rescue ArgumentError
      invalid_snapshot!(path)
    end

    def non_negative_decimal(raw, path)
      value = decimal(raw, path)
      invalid_snapshot!(path) if value.negative?

      value
    end

    def optional_decimal(raw, path)
      return if raw.nil?

      decimal(raw, path)
    rescue Provider::Scalable::Error
      nil
    end

    def close_enough?(left, right)
      (left - right).abs <= ROUNDING_TOLERANCE
    end

    def fits_database_decimal?(value, precision:, scale:)
      value.finite? && value.abs < BigDecimal("10")**(precision - scale)
    end

    def invalid_snapshot!(_path = nil)
      raise Provider::Scalable::Error.new(:invalid_snapshot)
    end
end
