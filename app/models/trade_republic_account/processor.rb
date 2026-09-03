class TradeRepublicAccount::Processor
  attr_reader :trade_republic_account

  def initialize(trade_republic_account)
    @trade_republic_account = trade_republic_account
  end

  def process
    return unless account.present?

    ActiveRecord::Base.transaction do
      update_account_balance!
      TradeRepublicAccount::HoldingsProcessor.new(trade_republic_account).process
      TradeRepublicAccount::ActivitiesProcessor.new(trade_republic_account).process
    end

    account.broadcast_sync_complete
  end

  private

    def account
      @account ||= trade_republic_account.current_account
    end

    def update_account_balance!
      total_balance = trade_republic_account.current_balance || 0
      cash_balance = trade_republic_account.cash_balance || 0

      account.assign_attributes(
        balance: total_balance,
        cash_balance: trade_republic_account.cash? ? cash_balance : 0,
        currency: trade_republic_account.currency
      )
      account.save!
      account.set_current_balance(total_balance)
    end
end
