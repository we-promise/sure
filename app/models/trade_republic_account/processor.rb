class TradeRepublicAccount::Processor
  attr_reader :trade_republic_account

  def initialize(trade_republic_account)
    @trade_republic_account = trade_republic_account
  end

  def process
    return unless account.present?

    exchange_securities = TradeRepublicAccount::SecurityPrefetcher.new(trade_republic_account).prefetch

    ActiveRecord::Base.transaction do
      total_balance = update_account_balance!
      TradeRepublicAccount::HoldingsProcessor.new(trade_republic_account, exchange_securities: exchange_securities).process
      TradeRepublicAccount::ActivitiesProcessor.new(trade_republic_account, exchange_securities: exchange_securities).process

      # TradeRepublicItem#schedule_account_syncs syncs the account once every
      # Trade Republic account has been processed. A sync started here would
      # run before the other accounts book their settlements, and then again.
      account.set_current_balance(total_balance, schedule_sync: false)
    end

    account.broadcast_sync_complete
  end

  private

    def account
      @account ||= trade_republic_account.current_account
    end

    def update_account_balance!
      total_balance = trade_republic_account.account_balance || 0
      cash_balance = trade_republic_account.cash_balance || 0

      account.assign_attributes(
        balance: total_balance,
        cash_balance: trade_republic_account.cash? ? cash_balance : 0,
        currency: trade_republic_account.currency
      )
      account.save!

      # Returned to `process`, which anchors it once holdings and activities are in.
      total_balance
    end
end
