# frozen_string_literal: true

class TricountAccount::Processor
  include TricountAccount::DataHelpers

  # The tricount's currency no longer matches the linked account's.
  class CurrencyChangedError < StandardError; end
  # The balance anchor couldn't be written.
  class AnchorError < StandardError; end

  attr_reader :tricount_account

  def initialize(tricount_account)
    @tricount_account = tricount_account
  end

  def process
    account = tricount_account.current_account
    return unless account

    Rails.logger.info "TricountAccount::Processor - Processing account #{tricount_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Run even when the tricount has no entries left, so transactions of
    # entries deleted in Tricount are removed.
    result = TricountAccount::Transactions::Processor.new(tricount_account).process

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "TricountAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: result[:total].positive?, transactions_removed: result[:removed], transactions_failed: result[:failed] }
  end

  private

    def update_account_balance(account)
      # What the group owes the owner; negative when the owner owes the group.
      balance = tricount_account.current_balance || 0

      Rails.logger.info "TricountAccount::Processor - Balance update: #{balance}"

      # The account keeps the currency it was linked in: switching it would
      # reinterpret its history in another currency. A tricount whose
      # currency changed is reported instead, and the account left alone.
      if tricount_account.currency.present? && tricount_account.currency != account.currency
        raise CurrencyChangedError, I18n.t("tricount_items.sync.errors.currency_changed", tricount_currency: tricount_account.currency, account_currency: account.currency)
      end

      # The balance and its anchor go together: an anchor that can't be
      # written fails the account's processing (and the sync's health) and
      # leaves the balance as it was. The account's own sync is scheduled once
      # every leg is imported (TricountItem#schedule_account_syncs).
      Account.transaction do
        account.update!(balance: balance, cash_balance: balance)
        result = account.set_current_balance(balance, schedule_sync: false)
        raise AnchorError, I18n.t("tricount_items.sync.errors.anchor_failed", error: result.error) unless result.success?
      end
    end
end
