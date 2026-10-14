# frozen_string_literal: true

class GocardlessAccount::Processor
  include GocardlessAccount::DataHelpers

  attr_reader :gocardless_account

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
  end

  def process
    account = gocardless_account.current_account
    return unless account

    Rails.logger.info "GocardlessAccount::Processor - Processing account #{gocardless_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Process transactions
    transactions_count = gocardless_account.raw_transactions_payload&.size || 0
    Rails.logger.info "GocardlessAccount::Processor - Transactions payload has #{transactions_count} items"

    if gocardless_account.raw_transactions_payload.present?
      Rails.logger.info "GocardlessAccount::Processor - Processing transactions..."
      GocardlessAccount::Transactions::Processor.new(gocardless_account).process
    else
      Rails.logger.warn "GocardlessAccount::Processor - No transactions payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "GocardlessAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: transactions_count > 0 }
  end

  private

    def update_account_balance(account)
      # Get balance from provider data
      balance = gocardless_account.current_balance || 0

      # The provider account already normalises liabilities to Sure's convention.
      Rails.logger.info "GocardlessAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: gocardless_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(balance)
    end
end
