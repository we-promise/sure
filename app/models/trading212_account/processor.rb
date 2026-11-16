class Trading212Account::Processor
  attr_reader :trading212_account

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    return unless account.present?

    update_account_balance!
    Trading212Account::HoldingsProcessor.new(trading212_account).process
    Trading212Account::ActivitiesProcessor.new(trading212_account).process

    account.broadcast_sync_complete
  end

  private

    def account
      @account ||= trading212_account.current_account
    end

    def update_account_balance!
      total_balance = trading212_account.current_balance || 0
      cash_balance = trading212_account.cash_balance || 0

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: trading212_account.currency
      )
      account.save!
      account.set_current_balance(total_balance)
    end
end
