# frozen_string_literal: true

class PluggyAccount::Processor
  include PluggyAccount::DataHelpers

  attr_reader :pluggy_account

  def initialize(pluggy_account)
    @pluggy_account = pluggy_account
  end

  # Dispatch a linked Pluggy account to the right child processor based on the
  # account type recorded in the snapshot: banking accounts → transactions,
  # investment accounts → holdings. The linked Account's balance is upserted
  # first so it stays current regardless of which child processor runs. Auth
  # errors are re-raised so the importer/syncer can mark the item for reconnect.
  def process
    return unless account.present?

    upsert_balance
    investment? ? process_investments : process_banking
  rescue Provider::Pluggy::AuthenticationError
    raise
  rescue => e
    Rails.logger.error "PluggyAccount::Processor - Failed for #{pluggy_account.id}: #{e.class} - #{e.message}"
    { error: e.message }
  end

  private

    def account
      @account ||= pluggy_account.current_account
    end

    def investment?
      type = (pluggy_account.raw_payload || {})["type"] || pluggy_account.account_type
      type.to_s.downcase == "investment"
    end

    # Upsert the linked Account's balance. Pluggy reports credit-card/loan
    # balances as negative for a positive position, so negate to match Sure's
    # sign convention (positive = money-out) on those accountables.
    def upsert_balance
      balance = pluggy_account.current_balance || 0
      balance = -balance if account.accountable_type.in?([ "CreditCard", "Loan" ])

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: pluggy_account.currency || account.currency
      )
      account.save!
      # Anchor the current-balance valuation so reverse sync reconciles correctly.
      account.set_current_balance(balance)
    end

    def process_banking
      transactions_count = pluggy_account.raw_transactions_payload&.size || 0
      if pluggy_account.raw_transactions_payload.present?
        PluggyAccount::Transactions::Processor.new(pluggy_account).process
      end
      account.broadcast_sync_complete
      { transactions: transactions_count > 0 }
    end

    def process_investments
      PluggyAccount::Investments::HoldingsProcessor.new(pluggy_account).process
      account.broadcast_sync_complete
      { holdings: true }
    end
end
