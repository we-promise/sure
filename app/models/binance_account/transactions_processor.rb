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
        amount = decimal(deposit["valuation_amount"])
        next if amount.zero?

        import_adapter.import_transaction(
          external_id: "binance_deposit_#{deposit['id']}",
          amount: -amount.abs,
          currency: binance_account.currency,
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
          investment_activity_label: "Transfer"
        )
      end
    end

    def process_withdrawals
      Array(payload[:withdrawals]).sort_by { |withdrawal| withdrawal["completeTime"] || withdrawal["applyTime"] || "" }.each do |withdrawal|
        amount = decimal(withdrawal["valuation_amount"])
        fee_amount = decimal(withdrawal["fee_valuation_amount"])
        total_amount = amount + fee_amount
        next if total_amount.zero?

        import_adapter.import_transaction(
          external_id: "binance_withdraw_#{withdrawal['id']}",
          amount: total_amount.abs,
          currency: binance_account.currency,
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
          investment_activity_label: "Transfer"
        )
      end
    end

    def process_trades
      Array(payload[:trades]).sort_by { |trade| trade["time"].to_i }.each do |trade|
        amount = decimal(trade["valuation_amount"])
        price = decimal(trade["valuation_price"])
        next if amount.zero? || price.zero?

        quantity = decimal(trade["qty"]).abs
        quantity *= -1 unless ActiveModel::Type::Boolean.new.cast(trade["isBuyer"])

        security = resolve_security(trade["base_asset"])
        next unless security

        entry = import_adapter.import_trade(
          external_id: "binance_trade_#{trade['symbol']}_#{trade['id']}",
          security: security,
          quantity: quantity,
          price: price,
          amount: quantity.positive? ? amount.abs : -amount.abs,
          currency: binance_account.currency,
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
end
