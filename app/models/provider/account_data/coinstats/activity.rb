require "digest"

class Provider::AccountData::Coinstats::Activity
  include Provider::AccountData::Normalization

  TRADE_TYPES = %w[buy sell swap trade convert fill].freeze
  OUTFLOW_TYPES = %w[sent send sell withdraw transfer_out swap_out].freeze
  LABELS = { "buy" => "Buy", "sell" => "Sell", "swap" => "Other", "trade" => "Other", "convert" => "Other",
    "received" => "Transfer", "receive" => "Transfer", "deposit" => "Transfer", "transfer_in" => "Transfer", "roll_in" => "Transfer",
    "sent" => "Transfer", "send" => "Transfer", "withdraw" => "Transfer", "transfer_out" => "Transfer", "roll_out" => "Transfer",
    "reward" => "Interest", "interest" => "Interest", "dividend" => "Dividend", "fee" => "Fee" }.freeze

  def initialize(descriptor:, account_name:, currency:, timezone:)
    @descriptor = descriptor.with_indifferent_access
    @account_name, @currency, @timezone = account_name, normalized_currency(currency), timezone
  end

  def self.identity(raw)
    raise ArgumentError unless raw.is_a?(Hash)
    row = raw.with_indifferent_access
    id = row.dig(:hash, :id).presence || row.dig(:transactions, 0, :items, 0, :id).presence
    return "coinstats_#{id}" if id.is_a?(String) && id.present?
    raise ArgumentError unless [ row[:date], row[:type], row.dig(:coinData, :count) ].all?(&:present?)
    components = [ row[:date], row[:type], row.dig(:coinData, :count), row.dig(:coinData, :symbol),
      row.dig(:fee, :count), row.dig(:fee, :coin, :symbol), row.dig(:transactions, 0, :action),
      row.dig(:transactions, 0, :items, 0, :coin, :id), row.dig(:transactions, 0, :items, 0, :count) ].compact
    # Legacy JSON parsing used binary floats in the identity preimage. Reproduce
    # only that spelling; monetary values never pass through this conversion.
    content = components.map do |value|
      if value.is_a?(BigDecimal) || value.is_a?(Float)
        raise ArgumentError unless value.finite? && value.to_f.finite?
        value.to_f.to_s
      elsif value.is_a?(String) || value.is_a?(Integer)
        value.to_s
      else
        raise ArgumentError
      end
    end.join("|")
    "coinstats_fallback_#{Digest::SHA256.hexdigest(content)[0, 16]}"
  end

  def self.exact_legacy_values(value)
    case value
    when Hash then value.to_h { |key, item| [ key, exact_legacy_values(item) ] }
    when Array then value.map { |item| exact_legacy_values(item) }
    when Float
      raise ArgumentError unless value.finite?
      BigDecimal(value.to_s)
    else value
    end
  end

  def self.decimal_strings(value)
    case value
    when Hash then value.to_h { |key, item| [ key, decimal_strings(item) ] }
    when Array then value.map { |item| decimal_strings(item) }
    when BigDecimal then value.to_s("F")
    else value
    end
  end

  def relevant?(raw)
    return true if @descriptor[:portfolio_account]
    row = normalized_object(raw)
    coin = normalized_object(row[:coinData] || {})
    id = @descriptor.fetch(:asset_id).downcase
    identifiers = [ coin[:identifier] ].compact.map { |value| value.to_s.downcase }
    identifiers.concat(items(row).flat_map do |item|
      metadata = normalized_object(item[:coin] || {})
      [ metadata[:id], metadata[:identifier], metadata[:symbol] ].compact.map { |value| value.to_s.downcase }
    end)
    identifiers.include?(id)
  end

  def normalize(raw, identity: self.class.identity(raw))
    row = normalized_object(raw)
    coin = normalized_object(row[:coinData] || {})
    profit = normalized_object(row[:profitLoss] || {})
    fee = normalized_object(row[:fee] || {})
    hash_data = normalized_object(row[:hash] || {})
    transaction_items = items(row)
    trade_item = if @descriptor[:portfolio_account]
      crypto = transaction_items.reject { |item| fiat_item?(item) || optional_decimal(item[:count]).zero? }
      crypto.find { |item| optional_decimal(item[:count]).negative? } || crypto.find { |item| optional_decimal(item[:count]).positive? }
    else
      transaction_items.find do |item|
        metadata = normalized_object(item[:coin] || {})
        metadata[:id].to_s.casecmp?(@descriptor.fetch(:asset_id)) || metadata[:identifier].to_s.casecmp?(@descriptor.fetch(:asset_id)) ||
          metadata[:symbol].to_s.casecmp?(@descriptor.fetch(:symbol))
      end
    end
    matched = trade_item || (@descriptor[:portfolio_account] && (transaction_items.find { |item| optional_decimal(item[:count]).nonzero? } || transaction_items.first))
    matched = nil if matched == false
    type = row[:type] || row[:transactionType] || "Transaction"
    raise ArgumentError unless type.is_a?(String)
    normalized_type = type.downcase.parameterize(separator: "_")
    symbol = matched&.dig(:coin, :symbol).presence || coin[:symbol]
    name = "#{type} #{symbol.presence || row.dig(:transactions, 0, :items, 0, :coin, :name)}".strip
    quantity = optional_decimal(trade_item&.[](:count)).nonzero? || optional_decimal(matched&.[](:count)).nonzero? || optional_decimal(coin[:count])
    worth = optional_decimal(trade_item&.[](:totalWorth)).nonzero? || optional_decimal(matched&.[](:totalWorth)).nonzero? ||
      coin[:currentValue] || coin[:totalWorth] || profit[:currentValue]
    price = quantity.zero? || worth.nil? ? BigDecimal("0") : decimal(worth).abs / quantity.abs
    if @descriptor[:source] == "exchange" && !@descriptor[:fiat] && TRADE_TYPES.include?(normalized_type) && !quantity.zero? && price.positive?
      ticker = trade_item&.dig(:coin, :symbol).presence || symbol.presence || @descriptor.fetch(:symbol)
      label = normalized_type == "sell" || quantity.negative? ? "Sell" : "Buy"
      return Ingestion::Record.activity(external_id: identity, name: name, activity_type: quantity.negative? ? "sell" : "buy", ledger_type: "trade",
        date: activity_date(row.fetch(:date)), currency: @currency, amount: quantity * price, quantity: quantity, price: price,
        security: { ticker: ticker.start_with?("CRYPTO:") ? ticker : "CRYPTO:#{ticker}" },
        metadata: { investment_activity_label: label, update_policy: "insert_only" })
    end
    absolute_amount, outflow = cash_amount(coin, profit, matched, quantity, normalized_type)
    extra = { transaction_hash: hash_data[:id], explorer_url: hash_data[:explorerUrl], transaction_type: type,
      symbol: coin[:symbol], count: coin[:count], profit: profit[:profit], profit_percent: profit[:profitPercent],
      fee_amount: fee[:count], fee_symbol: fee.dig(:coin, :symbol), fee_value: fee[:totalWorth], fee_usd: fee[:totalWorth] }.compact
    if matched
      extra[:matched_item] = { count: matched[:count], total_worth: matched[:totalWorth], coin_id: matched.dig(:coin, :id), coin_symbol: matched.dig(:coin, :symbol) }.compact
    end
    label = LABELS.fetch(normalized_type, "Other")
    Ingestion::Record.activity(external_id: identity, name: name, ledger_type: "transaction", activity_type: label.downcase,
      date: activity_date(row.fetch(:date)), currency: @currency, amount: outflow ? absolute_amount : -absolute_amount,
      metadata: { investment_activity_label: label, update_policy: "insert_only", notes: notes(coin, profit, fee, hash_data, trade_item, symbol),
        extra: { coinstats: self.class.decimal_strings(extra) },
        merchant: { external_id: "coinstats_account_#{@descriptor.fetch(:legacy_account_uuid)}", name: @account_name,
          logo_url: @descriptor[:institution_logo] }.compact })
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid CoinStats activity", cause: nil
  end

  private
    def items(row)
      %i[transactions transfers].flat_map do |key|
        values = row[key] || []
        raise ArgumentError unless values.is_a?(Array) && values.size <= 1000
        values.flat_map do |entry|
          nested = normalized_object(entry).fetch(:items, [])
          raise ArgumentError unless nested.is_a?(Array) && nested.size <= 1000
          nested.map { |item| normalized_object(item) }
        end
      end
    end

    def fiat_item?(item)
      metadata = normalized_object(item[:coin] || item)
      ActiveModel::Type::Boolean.new.cast(metadata[:isFiat]) == true ||
        metadata[:identifier].to_s.start_with?("FiatCoin") || metadata[:id].to_s.start_with?("FiatCoin")
    end

    def optional_decimal(value)
      value.nil? ? BigDecimal("0") : decimal(value)
    end

    def cash_amount(coin, profit, matched, quantity, type)
      outgoing = OUTFLOW_TYPES.include?(type)
      matched_worth = optional_decimal(matched&.[](:totalWorth))
      if @descriptor[:portfolio_account]
        value = matched_worth.abs.nonzero? || optional_decimal(coin[:currentValue]).abs.nonzero? || optional_decimal(profit[:currentValue]).abs.nonzero?
        value ||= BigDecimal("0") if matched&.key?(:totalWorth) || coin.key?(:currentValue) || profit.key?(:currentValue)
        outgoing ||= quantity.negative? || optional_decimal(matched&.[](:count)).negative? || optional_decimal(coin[:count]).negative?
      elsif @descriptor[:source] == "exchange" && @descriptor[:fiat]
        value = matched_worth.abs.nonzero? || coin[:count]
      else
        value = @descriptor[:source] == "exchange" ? matched_worth.nonzero? : nil
        value ||= coin[:currentValue] || profit[:currentValue]
        outgoing ||= optional_decimal(coin[:count]).negative?
      end
      # The old fallback was zero for missing valuation. Absence does not prove
      # a free transaction; preserve the evidence and quarantine that row.
      raise ArgumentError if value.nil?
      [ decimal(value).abs, outgoing ]
    end

    def notes(coin, profit, fee, hash_data, trade_item, symbol)
      parts = []
      count = optional_decimal(trade_item&.[](:count)).nonzero? || coin[:count]
      parts << "#{count} #{symbol}" if !count.nil? && symbol.present?
      parts << "Fee: #{display_value(fee[:count])} #{fee.dig(:coin, :symbol)}" if fee[:count].present? && fee.dig(:coin, :symbol).present?
      if profit[:profit].present?
        amount = decimal(profit[:profit]).round(2).to_s("F")
        percentage = optional_decimal(profit[:profitPercent]).round(2).to_s("F")
        display = @currency == "USD" ? "$#{amount}" : "#{amount} #{@currency}"
        parts << "P/L: #{display} (#{percentage}%)"
      end
      parts << "Explorer: #{hash_data[:explorerUrl]}" if hash_data[:explorerUrl].present?
      parts.presence&.join(" | ")
    end

    def display_value(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
    end

    def activity_date(value)
      return Time.at(value.to_r).in_time_zone(@timezone).to_date if value.is_a?(BigDecimal) && value.finite?
      date_in_zone(value)
    end
end
