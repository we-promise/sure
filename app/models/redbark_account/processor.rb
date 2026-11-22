# frozen_string_literal: true

class RedbarkAccount::Processor
  include RedbarkAccount::DataHelpers

  attr_reader :redbark_account, :as_of

  # `as_of` is the sync's own date, injected by the caller rather than read
  # here: a detected rate change is keyed by it (we-promise/sure#3891).
  def initialize(redbark_account, as_of: Date.current)
    @redbark_account = redbark_account
    @as_of = as_of
  end

  def process
    account = redbark_account.current_account
    return unless account

    Rails.logger.info "RedbarkAccount::Processor - Processing account #{redbark_account.id} -> Sure account #{account.id}"

    # Capture the reading's date before the import can cross midnight.
    date = Date.current

    # Update account balance FIRST (before processing transactions/holdings/activities)
    anchor_balance = update_account_balance(account)

    # Process transactions
    transactions_count = redbark_account.raw_transactions_payload&.size || 0
    Rails.logger.info "RedbarkAccount::Processor - Transactions payload has #{transactions_count} items"

    transactions_ok = true
    if redbark_account.raw_transactions_payload.present?
      Rails.logger.info "RedbarkAccount::Processor - Processing transactions..."
      transactions_ok = RedbarkAccount::Transactions::Processor.new(redbark_account).process[:success]
    else
      Rails.logger.warn "RedbarkAccount::Processor - No transactions payload to process"
    end

    if anchor_balance
      account.set_current_balance(
        anchor_balance,
        date: date,
        reuse_explained_anchor: transactions_ok
      )
    end

    # A loan's rate and a card's APR, read from what the bank reported. After
    # transactions, so a failure here cannot cost the user their entries; a
    # raise would be caught by RedbarkItem#process_accounts and logged per
    # account.
    RedbarkAccount::LoanDetailsProcessor.new(redbark_account, as_of: as_of).process
    RedbarkAccount::CreditCardDetailsProcessor.new(redbark_account, as_of: as_of).process

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
      # CreditCard and Loan balances are signed differently depending on the
      # upstream source (Fiskil/CDR — AU — reports the amount owed as a
      # negative balance; Plaid — US/CA — reports it as positive). The
      # provider-specific rule and the DebugLogEntry captured for an
      # unrecognised provider live on RedbarkAccount#normalized_liability_balance.
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = redbark_account.normalized_liability_balance(
          accountable_type: account.accountable_type,
          balance: balance,
          account: account
        )
      end

      Rails.logger.info "RedbarkAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: redbark_account.currency || account.currency
      )
      account.save!

      balance
    end
end
