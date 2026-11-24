class TinkoffInvestAccount::Processor
  attr_reader :tinkoff_invest_account

  def initialize(tinkoff_invest_account)
    @tinkoff_invest_account = tinkoff_invest_account
  end

  def process
    return { holdings: 0, trades: 0, transactions: 0 } unless account.present?

    date = Date.current

    total_balance = update_account_balance!
    holdings_count = TinkoffInvestAccount::HoldingsProcessor.new(tinkoff_invest_account).process
    activity_counts = TinkoffInvestAccount::ActivitiesProcessor.new(tinkoff_invest_account).process

    account.set_current_balance(total_balance, date: date)
    account.broadcast_sync_complete

    activity_counts.merge(holdings: holdings_count)
  end

  private

    def account
      @account ||= tinkoff_invest_account.current_account
    end

    def update_account_balance!
      total_balance = tinkoff_invest_account.current_balance || BigDecimal("0")
      cash_balance = tinkoff_invest_account.cash_balance || BigDecimal("0")

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: tinkoff_invest_account.currency
      )
      account.save!

      total_balance
    end
end
