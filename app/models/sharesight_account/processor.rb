class SharesightAccount::Processor
  attr_reader :sharesight_account

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
  end

  def process
    return unless account.present?

    update_account_balance!
    SharesightAccount::HoldingsProcessor.new(sharesight_account).process
    result = SharesightAccount::ActivitiesProcessor.new(sharesight_account).process

    account.broadcast_sync_complete
    result
  end

  private

    def account
      @account ||= sharesight_account.current_account
    end

    # The portfolio's value plus any Sharesight cash accounts. Without a cash
    # account there's no cash, so the balance is just the holdings.
    def update_account_balance!
      total_balance = sharesight_account.current_balance || 0
      cash_balance = sharesight_account.cash_balance || 0

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: sharesight_account.currency
      )
      account.save!
      account.set_current_balance(total_balance)
    end
end
