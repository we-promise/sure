# frozen_string_literal: true

class CoinspotAccount::Processor
  include CoinspotAccount::AudConverter

  attr_reader :coinspot_account

  # Initializes with the CoinspotAccount whose latest synced snapshot
  # (balances + transaction history) will be turned into a Sure account's
  # balance, holdings, and activity.
  def initialize(coinspot_account)
    @coinspot_account = coinspot_account
  end

  # Updates the linked Sure account's balance and imports every kind of
  # activity CoinSpot reports for it: holdings, orders, sends/receives, and
  # AUD deposits/withdrawals. No-op until the account is actually linked.
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

    # The family's base currency -- all imported amounts are converted into it.
    def target_currency
      coinspot_account.coinspot_item&.family&.currency
    end

    # The linked Sure account activity is imported into.
    def account
      coinspot_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Updates the linked account's balance from CoinSpot's reported total,
    # converted to the family currency, and records whether that conversion
    # used a stale (non-exact-date) FX rate.
    def process_account!
      amount, stale, rate_date = convert_from_aud((coinspot_account.current_balance || 0).to_d, date: Date.current)

      account.update!(
        balance: amount,
        cash_balance: 0,
        currency: target_currency
      )

      coinspot_account.update!(extra: coinspot_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date)))
    end

    # Imports every buy/sell order from the three shapes CoinSpot's history
    # endpoints can return them in: the primary buy/sell-order history, and
    # the market-order fallback (a flat "orders" list whose type is inferred
    # per order rather than split by endpoint).
    def process_orders
      Array(raw_transactions.dig("orders", "buyorders")).each { |order| process_order(order, "buy") }
      Array(raw_transactions.dig("orders", "sellorders")).each { |order| process_order(order, "sell") }
      Array(raw_transactions.dig("orders", "orders")).each { |order| process_order(order, infer_order_type(order)) }
    end

    # Imports one buy/sell order as a trade, plus its fee as a separate
    # transaction when CoinSpot reports one. A single order's failure is
    # captured to DebugLogEntry and skipped rather than aborting the batch.
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
      price = trade_price(amount: amount, quantity: quantity, fallback_rate: rate, date: date)
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

    # Imports every on-chain send and receive as account activity.
    def process_send_receive
      Array(raw_transactions.dig("send_receive", "sendtransactions")).each do |transaction|
        process_coin_movement(transaction, "send")
      end
      Array(raw_transactions.dig("send_receive", "receivetransactions")).each do |transaction|
        process_coin_movement(transaction, "receive")
      end
    end

    # Imports one on-chain send/receive as a contribution (receive) or
    # withdrawal (send) transaction, plus its network fee (converted from the
    # native asset to AUD) as a separate transaction when CoinSpot reports one.
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

    # Imports every AUD deposit as account activity.
    def process_fiat_deposits
      Array(raw_transactions.dig("deposits", "deposits")).each do |deposit|
        process_fiat_movement(deposit, "deposit")
      end
    end

    # Imports every AUD withdrawal as account activity.
    def process_fiat_withdrawals
      Array(raw_transactions.dig("withdrawals", "withdrawals")).each do |withdrawal|
        process_fiat_movement(withdrawal, "withdrawal")
      end
    end

    # Imports one AUD deposit/withdrawal as a contribution/withdrawal transaction.
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

    # Imports a fee (already in AUD) as its own transaction, keyed off a hash
    # of the source record so re-processing the same history doesn't duplicate it.
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

    # Converts a network fee denominated in the traded asset itself into AUD,
    # using that asset's price from the current balance snapshot. Returns nil
    # when there's nothing to convert or no price is available.
    def native_fee_to_aud(native_fee, symbol)
      fee = native_fee.presence&.to_d
      return nil unless fee&.positive?

      price_aud = asset_price_aud(symbol)
      return nil unless price_aud&.positive?

      fee * price_aud
    end

    # The asset's AUD price from the account's latest balance snapshot.
    def asset_price_aud(symbol)
      Array(coinspot_account.raw_payload&.dig("assets")).find do |asset|
        asset["symbol"] == symbol
      end&.dig("price_aud")&.to_d
    end

    # The cached order/transfer/deposit/withdrawal history payload for this account.
    def raw_transactions
      coinspot_account.raw_transactions_payload || {}
    end

    # Per-unit trade price in the account's currency. Prefers deriving it
    # from the already-converted amount and quantity (correct for every
    # order type, including crypto-to-crypto market orders where CoinSpot's
    # own `rate` field is denominated in the market's quote asset rather than
    # AUD); only falls back to converting `rate` from AUD when amount or
    # quantity aren't usable.
    def trade_price(amount:, quantity:, fallback_rate:, date:)
      return amount.abs / quantity.abs if quantity.present? && !quantity.zero? && amount.present? && !amount.zero?

      fallback_price, = convert_from_aud(fallback_rate, date: date)
      fallback_price
    end

    # CoinSpot's flat market-order-history fallback doesn't split buy/sell
    # into separate lists like the primary history endpoint does, so the type
    # has to be read off each order individually.
    def infer_order_type(order)
      order["type"].to_s.downcase == "sell" ? "sell" : "buy"
    end

    # The base asset symbol from a "BASE/QUOTE" market pair (e.g. "ETH" from "ETH/BTC").
    def market_base(market)
      market.to_s.split("/").first
    end

    # Stable external id for a trade, so re-importing the same order history
    # updates rather than duplicates it. Falls back to a content hash when
    # CoinSpot doesn't supply its own order id.
    def order_external_id(order, type, symbol, date)
      id = order["id"].presence || Digest::SHA256.hexdigest(order.to_json)[0, 24]
      "coinspot_order_#{type}_#{symbol}_#{date}_#{id}"
    end

    # Stable external id for a send/receive transaction.
    def coin_movement_external_id(transaction, type, symbol, date)
      id = transaction["txid"].presence || transaction["reference"].presence || Digest::SHA256.hexdigest(transaction.to_json)[0, 24]
      "coinspot_#{type}_#{symbol}_#{date}_#{id}"
    end

    # Stable external id for an AUD deposit/withdrawal transaction.
    def fiat_external_id(transaction, type, date)
      id = transaction["reference"].presence || Digest::SHA256.hexdigest(transaction.to_json)[0, 24]
      "coinspot_#{type}_aud_#{date}_#{id}"
    end

    # Parses a CoinSpot timestamp string, returning nil rather than raising
    # on anything unparseable.
    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Metadata recording whether the account balance's AUD conversion used a
    # stale (non-exact-date) exchange rate, surfaced on the account so the UI
    # can flag an approximate balance.
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
