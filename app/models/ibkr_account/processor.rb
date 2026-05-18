class IbkrAccount::Processor
  attr_reader :ibkr_account

  def initialize(ibkr_account)
    @ibkr_account = ibkr_account
  end

  def process
    return unless account.present?

    update_account_balance!
    IbkrAccount::HoldingsProcessor.new(ibkr_account).process
    IbkrAccount::ActivitiesProcessor.new(ibkr_account).process
    repair_default_opening_anchor!

    account.broadcast_sync_complete
  end

  private

    def account
      @account ||= ibkr_account.current_account
    end

    def update_account_balance!
      total_balance = ibkr_account.current_balance || ibkr_account.cash_balance || 0
      cash_balance = ibkr_account.cash_balance || 0

      account.assign_attributes(
        balance: total_balance,
        cash_balance: cash_balance,
        currency: ibkr_account.currency
      )
      account.save!
      account.set_current_balance(total_balance)
    end

    def repair_default_opening_anchor!
      return unless account&.linked_to?("IbkrAccount")
      return unless account.has_opening_anchor?

      opening_anchor_entry = account.valuations.opening_anchor.includes(:entry).first&.entry
      return unless opening_anchor_entry
      return unless opening_anchor_entry.created_at.to_date == account.created_at.to_date
      return unless account.entries.where.not(entryable_type: "Valuation").exists?

      imported_current_balance = (ibkr_account.current_balance || ibkr_account.cash_balance || 0).to_d
      return unless opening_anchor_entry.amount.to_d == imported_current_balance

      result = Account::OpeningBalanceManager.new(account).set_opening_balance(
        balance: 0,
        date: opening_anchor_entry.date
      )

      # Don't raise — broadcast_sync_complete must still run after a repair failure.
      if result.error
        Rails.logger.error(
          "IbkrAccount::Processor - Failed to repair opening anchor for account #{account.id}: #{result.error}"
        )
        Sentry.capture_message(result.error)
      end
    end
end
