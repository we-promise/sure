class BinanceAccount::TransactionsProcessor
  def initialize(binance_account)
    @binance_account = binance_account
  end

  def process
    return unless account.present?

    process_deposits
    process_withdrawals
    process_trades
  end

  private

    attr_reader :binance_account

    def account
      binance_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def payload
      @payload ||= (binance_account.raw_transactions_payload || {}).with_indifferent_access
    end

    def process_deposits
      Array(payload[:deposits]).sort_by { |deposit| deposit["completeTime"] || deposit["insertTime"] || 0 }.each do |deposit|
        amount, currency = deposit_amount_and_currency(deposit)
        next if amount.zero?

        import_adapter.import_transaction(
          external_id: "binance_deposit_#{deposit_identifier(deposit)}",
          amount: amount.abs,
          currency: currency,
          date: parse_date(deposit["completeTime"]) || parse_date(deposit["insertTime"]) || Date.current,
          name: "Deposit #{deposit['coin']}",
          source: "binance",
          notes: transfer_notes(deposit, type: "deposit"),
          extra: {
            "binance" => {
              "type" => "deposit",
              "coin" => deposit["coin"],
              "network" => deposit["network"],
              "tx_id" => deposit["txId"],
              "status" => deposit["status"],
              "original_amount" => deposit["amount"],
              "original_currency" => deposit["coin"],
              "valuation_source" => deposit["valuation_source"]
            }.compact
          },
          investment_activity_label: "Contribution"
        )
      end
    end

    def process_withdrawals
      Array(payload[:withdrawals]).sort_by { |withdrawal| withdrawal["completeTime"] || withdrawal["applyTime"] || "" }.each do |withdrawal|
        total_amount, currency = withdrawal_amount_and_currency(withdrawal)
        next if total_amount.zero?

        import_adapter.import_transaction(
          external_id: "binance_withdraw_#{withdrawal_identifier(withdrawal)}",
          amount: -total_amount.abs,
          currency: currency,
          date: parse_date(withdrawal["completeTime"]) || parse_date(withdrawal["applyTime"]) || Date.current,
          name: "Withdrawal #{withdrawal['coin']}",
          source: "binance",
          notes: transfer_notes(withdrawal, type: "withdrawal"),
          extra: {
            "binance" => {
              "type" => "withdrawal",
              "coin" => withdrawal["coin"],
              "network" => withdrawal["network"],
              "tx_id" => withdrawal["txId"],
              "status" => withdrawal["status"],
              "fee_amount" => withdrawal["transactionFee"],
              "fee_currency" => withdrawal["coin"],
              "original_amount" => withdrawal["amount"],
              "original_currency" => withdrawal["coin"],
              "valuation_source" => withdrawal["valuation_source"]
            }.compact
          },
          investment_activity_label: "Withdrawal"
        )
      end
    end

    def process_trades
      Array(payload[:trades]).sort_by { |trade| trade["time"].to_i }.each do |trade|
        quantity = decimal(trade["qty"]).abs
        amount, price, currency = trade_amount_price_and_currency(trade)
        next if amount.zero? || price.zero? || quantity.zero?

        quantity *= -1 unless ActiveModel::Type::Boolean.new.cast(trade["isBuyer"])

        security = resolve_security(trade["base_asset"])
        next unless security

        entry = import_adapter.import_trade(
          external_id: "binance_trade_#{trade['symbol']}_#{trade['id']}",
          security: security,
          quantity: quantity,
          price: price,
          amount: quantity.positive? ? -amount.abs : amount.abs,
          currency: currency,
          date: Time.zone.at(trade["time"].to_i / 1000.0).to_date,
          name: trade_name(trade, quantity),
          source: "binance",
          activity_label: quantity.positive? ? "Buy" : "Sell"
        )

        notes = trade_notes(trade)
        if notes.present? && entry.respond_to?(:enrich_attribute)
          entry.enrich_attribute(:notes, notes, source: "binance")
          entry.save! if entry.changed?
        end
      end
    end

    def resolve_security(asset)
      ticker = asset.to_s.upcase
      Security::Resolver.new("CRYPTO:#{ticker}").resolve
    rescue => e
      Rails.logger.warn("BinanceAccount::TransactionsProcessor - Resolver failed for #{asset}: #{e.class} - #{e.message}")
      Security.find_or_initialize_by(ticker: "CRYPTO:#{ticker}").tap do |security|
        security.offline = true if security.respond_to?(:offline=) && security.offline != true
        security.name = ticker if security.name.blank?
        security.save! if security.changed?
      end
    end

    def trade_name(trade, quantity)
      action = quantity.positive? ? "Buy" : "Sell"
      "#{action} #{decimal(trade['qty']).abs.to_s('F')} #{trade['base_asset']}"
    end

    def trade_notes(trade)
      parts = []
      parts << "Pair: #{trade['symbol']}" if trade["symbol"].present?
      parts << "Quote amount: #{trade['quoteQty']} #{trade['quote_asset']}" if trade["quoteQty"].present? && trade["quote_asset"].present?
      if trade["commission"].present? && decimal(trade["commission"]).positive?
        parts << "Fee: #{trade['commission']} #{trade['commission_asset']}"
      end
      parts << "Valuation source: #{trade['valuation_source']}" if trade["valuation_source"].present?
      parts.presence&.join(" | ")
    end

    def transfer_notes(event, type:)
      parts = []
      parts << "#{type.capitalize}: #{event['amount']} #{event['coin']}" if event["amount"].present? && event["coin"].present?
      parts << "Fee: #{event['transactionFee']} #{event['coin']}" if event["transactionFee"].present? && decimal(event["transactionFee"]).positive?
      parts << "Network: #{event['network']}" if event["network"].present?
      parts << "TxID: #{event['txId']}" if event["txId"].present?
      parts << "Valuation source: #{event['valuation_source']}" if event["valuation_source"].present?
      parts.presence&.join(" | ")
    end

    def parse_date(value)
      case value
      when Integer
        Time.zone.at(value / 1000.0).to_date
      when Float
        Time.zone.at(value / 1000.0).to_date
      when String
        return nil if value.blank?

        if value.match?(/\A\d+\z/)
          Time.zone.at(value.to_f / 1000.0).to_date
        else
          Time.find_zone!("UTC").parse(value).to_date
        end
      end
    rescue ArgumentError, TypeError
      nil
    end

    def decimal(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def deposit_amount_and_currency(deposit)
      valuation_amount = decimal(deposit["valuation_amount"])
      return [ valuation_amount, deposit["valuation_currency"].presence || binance_account.currency ] if valuation_amount.positive?

      [ decimal(deposit["amount"]), deposit["coin"].presence || binance_account.currency ]
    end

    def withdrawal_amount_and_currency(withdrawal)
      valuation_amount = decimal(withdrawal["valuation_amount"])
      if valuation_amount.positive?
        fee_amount = decimal(withdrawal["fee_valuation_amount"])
        return [
          valuation_amount + fee_amount.abs,
          withdrawal["valuation_currency"].presence || binance_account.currency
        ]
      end

      [
        decimal(withdrawal["amount"]) + decimal(withdrawal["transactionFee"]).abs,
        withdrawal["coin"].presence || binance_account.currency
      ]
    end

    def trade_amount_price_and_currency(trade)
      valuation_amount = decimal(trade["valuation_amount"])
      valuation_price = decimal(trade["valuation_price"])

      if valuation_amount.positive? && valuation_price.positive?
        fee_amount = decimal(trade["commission_valuation_amount"])
        net_amount = apply_trade_fee(
          base_amount: valuation_amount,
          fee_amount: fee_amount,
          buyer: ActiveModel::Type::Boolean.new.cast(trade["isBuyer"])
        )

        return [
          net_amount,
          valuation_price,
          trade["valuation_currency"].presence || binance_account.currency
        ]
      end

      quote_amount = decimal(trade["quoteQty"])
      raw_price = decimal(trade["price"])
      fee_amount = trade["commission_asset"].to_s.upcase == trade["quote_asset"].to_s.upcase ? decimal(trade["commission"]) : 0.to_d

      [
        apply_trade_fee(
          base_amount: quote_amount,
          fee_amount: fee_amount,
          buyer: ActiveModel::Type::Boolean.new.cast(trade["isBuyer"])
        ),
        raw_price,
        trade["quote_asset"].presence || binance_account.currency
      ]
    end

    def apply_trade_fee(base_amount:, fee_amount:, buyer:)
      buyer ? base_amount + fee_amount.abs : base_amount - fee_amount.abs
    end

    def deposit_identifier(deposit)
      event_identifier(
        deposit,
        primary_keys: %w[id txId tranId],
        fallback_keys: %w[coin amount completeTime insertTime]
      )
    end

    def withdrawal_identifier(withdrawal)
      event_identifier(
        withdrawal,
        primary_keys: %w[id txId tranId],
        fallback_keys: %w[coin amount transactionFee completeTime applyTime]
      )
    end

    def event_identifier(event, primary_keys:, fallback_keys:)
      primary_keys.each do |key|
        value = event[key].presence
        return value if value.present?
      end

      fallback_values = fallback_keys.filter_map { |key| event[key].presence }
      return fallback_values.join("_") if fallback_values.any?

      SecureRandom.uuid
    end
end
