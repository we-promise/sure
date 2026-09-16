class Provider::AccountData::Coinstats::Values
  include Provider::AccountData::Normalization

  def initialize(exchange_rate_resolver:, observed_at:, timezone:)
    @exchange_rate_resolver, @observed_at, @timezone = exchange_rate_resolver, observed_at, timezone
  end

  def self.defi_identity(protocol, investment, asset, blockchain:)
    chain = blockchain.to_s.downcase.gsub(/\s+/, "_").presence || "unknown"
    protocol_id = protocol[:id].to_s.downcase.gsub(/\s+/, "_").presence || "unknown"
    coin_id = (asset[:coinId] || asset[:symbol]).to_s.downcase
    title = asset[:title].to_s.downcase.gsub(/\s+/, "_").presence || "position"
    investment_type = investment[:name].to_s.downcase.gsub(/\s+/, "_").presence
    parts = [ "defi", chain, protocol_id, coin_id, title ]
    parts.insert(3, investment_type) if investment_type
    parts.join(":")
  end

  def coin_identity(raw)
    row = normalized_object(raw)
    coin = normalized_object(row[:coin] || {})
    normalized_id(coin[:identifier].presence || row[:id].presence || row[:coinId].presence || coin[:symbol].presence || row[:symbol])
  end

  def snapshot(coins, descriptor:, family_currency:, observed_at:, account_currency:)
    descriptor = descriptor.with_indifferent_access
    rows = coins.map { |row| normalized_object(row) }
    source = descriptor.fetch(:source)
    unless descriptor.fetch(:portfolio_account)
      matches = rows.select { |row| matching_coin?(row, descriptor) }
      raise ArgumentError unless matches.one?
      rows = matches
    end
    @date = Time.iso8601(observed_at).in_time_zone(@timezone).to_date
    @rates = []
    code = case source
    when "exchange" then descriptor[:fiat] ? normalized_currency(descriptor[:symbol]) : normalized_currency(family_currency)
    when "defi" then normalized_currency(family_currency)
    else descriptor[:fiat] ? normalized_currency(descriptor[:symbol]) : "USD"
    end
    if source == "defi"
      total = currency_value(rows.sole.fetch(:defi_total_value), code, allow_usd_fallback: true)
      code = total.fetch(:currency)
    end
    total_balance, cash, positions = BigDecimal("0"), BigDecimal("0"), []
    rows.each do |row|
      quantity = decimal(row[:count] || row[:amount] || row[:balance] || row.fetch(:current_balance)).abs
      metadata = asset_metadata(row)
      fiat = descriptor[:portfolio_account] ? fiat?(row) : descriptor.fetch(:fiat)
      amount, price = if source == "defi"
        [ total.fetch(:amount), quantity.zero? ? BigDecimal("0") : total.fetch(:amount) / quantity ]
      elsif fiat
        native_currency = normalized_currency(metadata[:symbol] || descriptor[:symbol])
        value = convert(quantity, from: native_currency, to: code)
        [ value, quantity.zero? ? BigDecimal("0") : value / quantity ]
      else
        price = price_value(row, code)
        explicit = row[:currentValue] || row[:current_value] || row[:totalWorth]
        value = if source == "wallet"
          quantity * price
        elsif descriptor[:portfolio_account] && !explicit.nil?
          currency_value(explicit, code).fetch(:amount)
        else
          quantity * price
        end
        [ value, price ]
      end
      raise ArgumentError if amount.negative? || price.negative?
      total_balance += amount
      cash += amount if fiat
      next if fiat || quantity.zero?
      symbol = normalized_id(metadata[:symbol].presence || descriptor[:symbol])
      name = metadata[:name].presence || descriptor.fetch(:asset_name)
      identity = if descriptor[:portfolio_account]
        coin_id = metadata[:identifier].presence || metadata[:symbol].presence || row[:coinId].presence || row[:symbol]
        "coinstats_holding_#{descriptor.fetch(:asset_id)}_#{normalized_id(coin_id)}_#{@date}"
      else
        "coinstats_holding_#{descriptor.fetch(:asset_id)}_#{@date}"
      end
      cost_basis = average_buy(row, code)
      positions << { "external_id" => identity, "quantity" => quantity.to_s("F"), "price" => price.to_s("F"),
        "amount" => amount.to_s("F"), "cost_basis" => cost_basis&.to_s("F"),
        "ticker" => symbol.start_with?("CRYPTO:") ? symbol : "CRYPTO:#{symbol}", "name" => name }
    end
    raise ArgumentError unless positions.map { |position| position.fetch("external_id") }.uniq.size == positions.size
    { "version" => 1, "observed_at" => observed_at, "date" => @date.iso8601, "currency" => code,
      "descriptor_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(descriptor.to_h.sort.to_h)),
      "balance" => total_balance.to_s("F"), "cash_balance" => cash.to_s("F"), "positions" => positions,
      "fx_evidence" => @rates }
  end

  private
    def matching_coin?(row, descriptor)
      identity = descriptor.fetch(:asset_id)
      return row[:id] == identity if descriptor[:source] == "defi"
      metadata = asset_metadata(row)
      # Exact persisted identifiers precede an explicit symbol alias. Never use
      # a substring of the user's account name to choose a different instrument.
      ids = [ metadata[:identifier], row[:coinId], row[:id] ].compact.map(&:to_s)
      return ids.include?(identity) if ids.any?
      metadata[:symbol].to_s.casecmp?(descriptor.fetch(:symbol))
    end

    def asset_metadata(row)
      row[:coin].is_a?(Hash) ? normalized_object(row[:coin]) : row
    end

    def fiat?(row)
      metadata = asset_metadata(row)
      [ metadata[:isFiat], row[:isFiat] ].any? { |value| ActiveModel::Type::Boolean.new.cast(value) == true } ||
        [ metadata[:identifier], row[:coinId] ].any? { |value| value.to_s.start_with?("FiatCoin") }
    end

    def price_value(row, currency)
      raw = row[:price] || row[:priceUsd]
      raise ArgumentError if raw.nil?
      currency_value(raw, currency).fetch(:amount)
    end

    def currency_value(raw, currency, allow_usd_fallback: false)
      if raw.is_a?(Hash)
        values = normalized_object(raw)
        return { amount: decimal(values[currency]), currency: currency } unless values[currency].nil?
        raw = values.fetch(:USD)
      end
      amount = decimal(raw)
      if allow_usd_fallback && amount.zero?
        return { amount: amount, currency: "USD" }
      end
      { amount: convert(amount, from: "USD", to: currency), currency: currency }
    rescue MissingRate
      raise unless allow_usd_fallback
      { amount: amount, currency: "USD" }
    end

    def average_buy(row, currency)
      return if row[:averageBuy].blank?
      values = normalized_object(row[:averageBuy])
      all_time = normalized_object(values[:allTime] || {})
      value = values[currency] || all_time[currency]
      return decimal(value) unless value.nil?
      usd = values[:USD] || all_time[:USD]
      return if usd.nil?
      convert(decimal(usd), from: "USD", to: currency)
    end

    class MissingRate < ArgumentError; end

    def convert(amount, from:, to:)
      return amount if from == to
      result = @exchange_rate_resolver.call(from: from, to: to, date: @date)
      raise MissingRate unless result.is_a?(Hash)
      result = normalized_object(result)
      rate = decimal(result.fetch(:rate))
      actual_date = Date.iso8601(result.fetch(:date))
      raise MissingRate unless rate.positive? && actual_date <= @date
      evidence = { "from" => from, "to" => to, "date" => actual_date.iso8601, "rate" => rate.to_s("F") }
      @rates << evidence unless @rates.include?(evidence)
      amount * rate
    end
end
