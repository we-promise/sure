# frozen_string_literal: true

class RedbarkAccount::Processor
  include RedbarkAccount::DataHelpers

  attr_reader :redbark_account

  def initialize(redbark_account)
    @redbark_account = redbark_account
  end

  def process
    account = redbark_account.current_account
    return unless account

    Rails.logger.info "RedbarkAccount::Processor - Processing account #{redbark_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Process transactions
    transactions_count = redbark_account.raw_transactions_payload&.size || 0
    Rails.logger.info "RedbarkAccount::Processor - Transactions payload has #{transactions_count} items"

    if redbark_account.raw_transactions_payload.present?
      Rails.logger.info "RedbarkAccount::Processor - Processing transactions..."
      RedbarkAccount::Transactions::Processor.new(redbark_account).process
    else
      Rails.logger.warn "RedbarkAccount::Processor - No transactions payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "RedbarkAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: transactions_count > 0 }
  end

  private

    def update_account_balance(account)
      balance = redbark_account.current_balance

      # A nil current_balance means no balances fetch has succeeded for this
      # account yet. Writing 0 here would clobber a healthy balance (or the
      # opening balance the user typed during setup) and anchor a $0
      # valuation, so leave the account untouched instead.
      if balance.nil?
        Rails.logger.warn "RedbarkAccount::Processor - No balance available for redbark_account #{redbark_account.id}, skipping balance update"
        return
      end

      # Banking sign convention:
      # - CreditCard and Loan accounts may need sign inversion
      # Provider returns negative for positive balance, so we negate it
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = -balance
      end

      Rails.logger.info "RedbarkAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: redbark_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(balance)
    end
end
