# frozen_string_literal: true

class CoinspotAccount::Processor
  include CoinspotAccount::AudConverter

  class NativeFeeConversionUnavailableError < StandardError; end
  class UnknownOrderTypeError < StandardError; end
  class UnparseableTimestampError < StandardError; end

  ORDER_TYPES = %w[buy sell].freeze

  # Serializes a record with hash keys sorted recursively (array order is
  # preserved, since it carries meaning) so a content hash identifies the
  # record itself rather than the key order the provider happened to send.
  def self.canonical_json(record)
    deep_sort_keys(record).to_json
  end

  def self.deep_sort_keys(value)
    case value
    when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, nested| [ key, deep_sort_keys(nested) ] }
    when Array then value.map { |element| deep_sort_keys(element) }
    else value
    end
  end

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

    holdings_result = CoinspotAccount::HoldingsProcessor.new(coinspot_account).process
    failures = Array(holdings_result&.dig(:failures))
    process_account!
    failures.concat(process_orders)
    failures.concat(process_send_receive)
    failures.concat(process_fiat_deposits)
    failures.concat(process_fiat_withdrawals)

    { success: failures.empty?, failures: failures }
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
      failures = []
      Array(raw_transactions.dig("orders", "buyorders")).each { |order| failures << process_order(order, "buy") }
      Array(raw_transactions.dig("orders", "sellorders")).each { |order| failures << process_order(order, "sell") }
      Array(raw_transactions.dig("orders", "orders")).each { |order| failures << process_order(order, infer_order_type(order)) }
      failures.compact
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
      order_type = validate_order_type!(type)
      date = parse_date!(order["solddate"] || order["created"], "order")
      type = order_type
      signed_quantity = type == "sell" ? -quantity.abs : quantity.abs
      amount_aud = type == "sell" ? total_aud.abs : -total_aud.abs

      amount, = convert_from_aud(amount_aud, date: date)
      price = trade_price(amount: amount, quantity: quantity, fallback_rate: rate, date: date)
      external_id = order_external_id(order, type, symbol, date)

      Entry.transaction do
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
      end
      nil
    rescue StandardError => e
      log_record_failure("order", order, e)
    end

    # Imports every on-chain send and receive as account activity.
    def process_send_receive
      failures = []
      Array(raw_transactions.dig("send_receive", "sendtransactions")).each do |transaction|
        failures << process_coin_movement(transaction, "send")
      end
      Array(raw_transactions.dig("send_receive", "receivetransactions")).each do |transaction|
        failures << process_coin_movement(transaction, "receive")
      end
      failures.compact
    end

    # Imports one on-chain send/receive as a contribution (receive) or
    # withdrawal (send) transaction, plus its network fee (converted from the
    # native asset to AUD) as a separate transaction when CoinSpot reports one.
    def process_coin_movement(transaction, type)
      symbol = CoinspotAccount::SecurityResolver.normalize_symbol(transaction["coin"])
      date = parse_date!(transaction["timestamp"], "send_receive")
      aud_amount = transaction["aud"].to_d
      signed_amount = type == "receive" ? -aud_amount.abs : aud_amount.abs
      amount, = convert_from_aud(signed_amount, date: date)
      label = type == "receive" ? "Contribution" : "Withdrawal"
      external_id = coin_movement_external_id(transaction, type, symbol, date)

      Entry.transaction do
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

        send_fee_aud = native_fee_to_aud(transaction["sendfee"], transaction)
        import_fee(transaction, send_fee_aud, date, symbol) if send_fee_aud&.positive?
      end
      nil
    rescue StandardError => e
      log_record_failure("send_receive", transaction, e)
    end

    # Imports every AUD deposit as account activity.
    def process_fiat_deposits
      failures = []
      Array(raw_transactions.dig("deposits", "deposits")).each do |deposit|
        failures << process_fiat_movement(deposit, "deposit")
      end
      failures.compact
    end

    # Imports every AUD withdrawal as account activity.
    def process_fiat_withdrawals
      failures = []
      Array(raw_transactions.dig("withdrawals", "withdrawals")).each do |withdrawal|
        failures << process_fiat_movement(withdrawal, "withdrawal")
      end
      failures.compact
    end

    # Imports one AUD deposit/withdrawal as a contribution/withdrawal transaction.
    def process_fiat_movement(transaction, type)
      date = parse_date!(transaction["created"], type)
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
      nil
    rescue StandardError => e
      log_record_failure(type, transaction, e)
    end

    def log_record_failure(kind, record, error)
      details = sanitized_record(record)

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process CoinSpot #{kind} record: #{error.message}",
        source: self.class.name,
        provider_key: "coinspot",
        family: coinspot_account.coinspot_item&.family,
        metadata: { record: details, error_class: error.class.name }
      )
      { kind: kind, error: error.message, error_class: error.class.name, record: details }
    end

    # An allowlist, not a redaction list: the whole provider record used to go
    # into DebugLogEntry and into the failure result the syncer surfaces, which
    # put addresses, transaction ids and amounts in front of anyone who can
    # read the debug UI. Only what is needed to identify the failing record is
    # kept, and anything new CoinSpot adds is excluded by default.
    SAFE_RECORD_KEYS = %w[id txid reference coin market type].freeze

    def sanitized_record(record)
      return {} unless record.is_a?(Hash)

      record.slice(*SAFE_RECORD_KEYS)
    end

    # Imports a fee (already in AUD) as its own transaction, keyed off a hash
    # of the source record so re-processing the same history doesn't duplicate it.
    def import_fee(source_record, fee_aud, date, symbol)
      amount, = convert_from_aud(fee_aud.to_d.abs, date: date)
      fee_id = content_id(source_record) { |digest| "coinspot_fee_#{digest}" }
      external_id = "coinspot_fee_#{fee_id}"

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

    # Converts a network fee denominated in the transferred asset into AUD
    # using the transfer's own AUD value, which reflects the transaction date.
    def native_fee_to_aud(native_fee, transaction)
      fee = native_fee.presence&.to_d
      return nil unless fee&.positive?

      native_amount = transaction["amount"].to_d.abs
      aud_amount = transaction["aud"].to_d.abs
      unless native_amount.positive? && aud_amount.positive?
        raise NativeFeeConversionUnavailableError, "CoinSpot send fee has no transaction-date AUD valuation"
      end

      fee * aud_amount / native_amount
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
    # has to be read off each order individually. Anything unrecognised is
    # passed through verbatim for validate_order_type! to reject inside
    # process_order's rescue -- mapping it to "buy" here would silently record
    # a sell as a buy, with the wrong sign on both quantity and cash flow.
    def infer_order_type(order)
      order["type"].to_s.downcase.presence
    end

    # An order whose type isn't one of the two CoinSpot reports is a record we
    # cannot sign correctly, so it becomes a structured per-record failure
    # rather than a guess.
    def validate_order_type!(type)
      normalized = type.to_s.downcase
      return normalized if ORDER_TYPES.include?(normalized)

      raise UnknownOrderTypeError, "CoinSpot order has unknown type #{type.inspect}"
    end

    # A record whose timestamp can't be parsed would otherwise be stamped with
    # Date.current, and since the date is part of every external id, the next
    # sync that parses it correctly would import it a second time instead of
    # updating it.
    def parse_date!(value, kind)
      parsed = parse_time(value)&.to_date
      return parsed if parsed

      raise UnparseableTimestampError, "CoinSpot #{kind} record has unparseable timestamp #{value.inspect}"
    end

    # The base asset symbol from a "BASE/QUOTE" market pair (e.g. "ETH" from "ETH/BTC").
    def market_base(market)
      market.to_s.split("/").first
    end

    # Stable external id for a trade, so re-importing the same order history
    # updates rather than duplicates it. Falls back to a content hash when
    # CoinSpot doesn't supply its own order id.
    def order_external_id(order, type, symbol, date)
      id = order["id"].presence || content_id(order) { |digest| "coinspot_order_#{type}_#{symbol}_#{date}_#{digest}" }
      "coinspot_order_#{type}_#{symbol}_#{date}_#{id}"
    end

    # Stable external id for a send/receive transaction.
    def coin_movement_external_id(transaction, type, symbol, date)
      id = transaction["txid"].presence || transaction["reference"].presence ||
        content_id(transaction) { |digest| "coinspot_#{type}_#{symbol}_#{date}_#{digest}" }
      "coinspot_#{type}_#{symbol}_#{date}_#{id}"
    end

    # Stable external id for an AUD deposit/withdrawal transaction.
    def fiat_external_id(transaction, type, date)
      id = transaction["reference"].presence ||
        content_id(transaction) { |digest| "coinspot_#{type}_aud_#{date}_#{digest}" }
      "coinspot_#{type}_aud_#{date}_#{id}"
    end

    # Content hash for a record CoinSpot gave no id of its own.
    #
    # New records hash the key-sorted form, so a provider key-order change
    # can't produce a second id for the same record. Records imported before
    # that change were hashed unsorted, so the legacy digest is checked first
    # via the caller's id format: switching them to the canonical digest would
    # re-import every historical id-less trade, movement and fee as a
    # duplicate -- the exact harm the canonical form exists to prevent.
    def content_id(record)
      legacy = Digest::SHA256.hexdigest(record.to_json)[0, 24]
      return legacy if account.entries.exists?(external_id: yield(legacy), source: "coinspot")

      Digest::SHA256.hexdigest(self.class.canonical_json(record))[0, 24]
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
