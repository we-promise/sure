class BinanceAccount::Processor
  attr_reader :binance_account

  def initialize(binance_account)
    @binance_account = binance_account
  end

  def process
    account = binance_account.current_account
    return unless account

    update_account_balance(account)
    BinanceAccount::HoldingsProcessor.new(binance_account).process
    BinanceAccount::TransactionsProcessor.new(binance_account).process
    account.broadcast_sync_complete

    {
      holdings_processed: Array(binance_account.raw_holdings_payload).size,
      events_processed: Array(binance_account.raw_transactions_payload&.dig("deposits")).size +
        Array(binance_account.raw_transactions_payload&.dig("withdrawals")).size +
        Array(binance_account.raw_transactions_payload&.dig("trades")).size
    }
  end

  private

    def update_account_balance(account)
      total_balance = binance_account.current_balance || calculate_holdings_value

      account.assign_attributes(
        balance: total_balance,
        cash_balance: binance_account.cash_balance || 0,
        currency: binance_account.currency || account.currency
      )
      account.save!
      account.set_current_balance(total_balance)
    end

    def calculate_holdings_value
      Array(binance_account.raw_holdings_payload).sum { |holding| decimal(holding["amount"]) }
    end

    def decimal(value)
      return BigDecimal("0") if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
end
