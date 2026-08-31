# frozen_string_literal: true

class CoinspotAccount::Processor
  include CoinspotAccount::AudConverter

  attr_reader :coinspot_account

  def initialize(coinspot_account)
    @coinspot_account = coinspot_account
  end

  def process
    return unless coinspot_account.current_account.present?

    CoinspotAccount::HoldingsProcessor.new(coinspot_account).process
    process_account!
    process_orders
    process_send_receive
    process_fiat_deposits
    process_fiat_withdrawals
  end

  private

    def target_currency
      coinspot_account.coinspot_item&.family&.currency
    end

    def account
      coinspot_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_account!
      amount, stale, rate_date = convert_from_aud((coinspot_account.current_balance || 0).to_d, date: Date.current)

      account.update!(
        balance: amount,
        cash_balance: 0,
        currency: target_currency
      )

      coinspot_account.update!(extra: coinspot_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date)))
    end

    def process_orders
      Array(raw_transactions.dig("orders", "buyorders")).each { |order| process_order(order, "buy") }
      Array(raw_transactions.dig("orders", "sellorders")).each { |order| process_order(order, "sell") }
      Array(raw_transactions.dig("orders", "orders")).each { |order| process_order(order, infer_order_type(order)) }
    end

    def process_order(order, type)
      symbol = CoinspotAccount::SecurityResolver.normalize_symbol(order["coin"].presence || market_base(order["market"]))
      security = CoinspotAccount::SecurityResolver.resolve(symbol)
      return unless security

      quantity = order["amount"].to_d
      return if quantity.zero?

      rate = order["rate"].to_d
      total_aud = order["audtotal"].presence&.to_d || order["total"].to_d
      fee_aud = order["audfeeExGst"].to_d + order["audGst"].to_d
      date = parse_time(order["solddate"] || order["created"])&.to_date || Date.current
      signed_quantity = type == "sell" ? -quantity.abs : quantity.abs
      amount_aud = type == "sell" ? total_aud.abs : -total_aud.abs

      amount, = convert_from_aud(amount_aud, date: date)
      price, = convert_from_aud(rate, date: date)
      external_id = order_external_id(order, type, symbol, date)

      import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: signed_quantity,
        price: price,
        amount: amount,
        currency: target_currency,
        date: date,
        name: "#{type.capitalize} #{quantity.round(8)} #{symbol}",
        source: "coinspot",
        activity_label: type == "sell" ? "Sell" : "Buy"
      )

      import_fee(order, fee_aud, date, symbol) if fee_aud.positive?
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process CoinSpot order: #{e.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_account.coinspot_item&.family,
        metadata: { order: order, error_class: e.class.name }
      )
    end

    def process_send_receive
      Array(raw_transactions.dig("send_receive", "sendtransactions")).each do |transaction|
        process_coin_movement(transaction, "send")
      end
      Array(raw_transactions.dig("send_receive", "receivetransactions")).each do |transaction|
        process_coin_movement(transaction, "receive")
      end
    end

    def process_coin_movement(transaction, type)
      symbol = CoinspotAccount::SecurityResolver.normalize_symbol(transaction["coin"])
      date = parse_time(transaction["timestamp"])&.to_date || Date.current
      aud_amount = transaction["aud"].to_d
      signed_amount = type == "receive" ? -aud_amount.abs : aud_amount.abs
      amount, = convert_from_aud(signed_amount, date: date)
      label = type == "receive" ? "Contribution" : "Withdrawal"
      external_id = coin_movement_external_id(transaction, type, symbol, date)

      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: target_currency,
        date: date,
        name: "#{label} #{transaction["amount"]} #{symbol}",
        source: "coinspot",
        investment_activity_label: label,
        extra: { "coinspot" => transaction.merge("type" => type) }
      )

      send_fee_aud = native_fee_to_aud(transaction["sendfee"], symbol)
      import_fee(transaction, send_fee_aud, date, symbol) if send_fee_aud&.positive?
    end

    def process_fiat_deposits
      Array(raw_transactions.dig("deposits", "deposits")).each do |deposit|
        process_fiat_movement(deposit, "deposit")
      end
    end

    def process_fiat_withdrawals
      Array(raw_transactions.dig("withdrawals", "withdrawals")).each do |withdrawal|
        process_fiat_movement(withdrawal, "withdrawal")
      end
    end

    def process_fiat_movement(transaction, type)
      date = parse_time(transaction["created"])&.to_date || Date.current
      signed_aud = type == "deposit" ? -transaction["amount"].to_d.abs : transaction["amount"].to_d.abs
      amount, = convert_from_aud(signed_aud, date: date)
      label = type == "deposit" ? "Contribution" : "Withdrawal"
      external_id = fiat_external_id(transaction, type, date)

      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: target_currency,
        date: date,
        name: "CoinSpot #{label.downcase}",
        source: "coinspot",
        investment_activity_label: label,
        extra: { "coinspot" => transaction.merge("type" => type) }
      )
    end

    def import_fee(source_record, fee_aud, date, symbol)
      amount, = convert_from_aud(fee_aud.to_d.abs, date: date)
      external_id = "coinspot_fee_#{Digest::SHA256.hexdigest(source_record.to_json)[0, 24]}"

      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: target_currency,
        date: date,
        name: "CoinSpot fee #{symbol}",
        source: "coinspot",
        investment_activity_label: "Fee",
        extra: { "coinspot" => source_record.merge("fee_for" => symbol) }
      )
    end

    def native_fee_to_aud(native_fee, symbol)
      fee = native_fee.presence&.to_d
      return nil unless fee&.positive?

      price_aud = asset_price_aud(symbol)
      return nil unless price_aud&.positive?

      fee * price_aud
    end

    def asset_price_aud(symbol)
      Array(coinspot_account.raw_payload&.dig("assets")).find do |asset|
        asset["symbol"] == symbol
      end&.dig("price_aud")&.to_d
    end

    def raw_transactions
      coinspot_account.raw_transactions_payload || {}
    end

    def infer_order_type(order)
      order["type"].to_s.downcase == "sell" ? "sell" : "buy"
    end

    def market_base(market)
      market.to_s.split("/").first
    end

    def order_external_id(order, type, symbol, date)
      id = order["id"].presence || Digest::SHA256.hexdigest(order.to_json)[0, 24]
      "coinspot_order_#{type}_#{symbol}_#{date}_#{id}"
    end

    def coin_movement_external_id(transaction, type, symbol, date)
      id = transaction["txid"].presence || transaction["reference"].presence || Digest::SHA256.hexdigest(transaction.to_json)[0, 24]
      "coinspot_#{type}_#{symbol}_#{date}_#{id}"
    end

    def fiat_external_id(transaction, type, date)
      id = transaction["reference"].presence || Digest::SHA256.hexdigest(transaction.to_json)[0, 24]
      "coinspot_#{type}_aud_#{date}_#{id}"
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def build_stale_extra(stale, rate_date)
      {
        "coinspot" => {
          "stale_rate" => stale,
          "rate_target_date" => Date.current.to_s,
          "rate_used_date" => rate_date&.to_s
        }
      }
    end
end
