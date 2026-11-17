# frozen_string_literal: true

class QuestradeAccount::Processor
  include QuestradeAccount::DataHelpers

  attr_reader :questrade_account

  def initialize(questrade_account)
    @questrade_account = questrade_account
  end

  def process
    account = questrade_account.current_account
    return unless account

    Rails.logger.info "QuestradeAccount::Processor - Processing account #{questrade_account.id} -> Sure account #{account.id}"

    # Capture the reading's date before the import can cross midnight.
    date = Date.current

    # Store the reported total (cash + holdings) and the primary-currency cash.
    # Non-primary cash is surfaced as holdings below.
    anchor_balance = update_account_balance(account)

    if questrade_account.raw_holdings_payload.present? || questrade_account.non_primary_cash_entries.any?
      QuestradeAccount::HoldingsProcessor.new(questrade_account).process
    end

    if questrade_account.raw_activities_payload.present?
      QuestradeAccount::ActivitiesProcessor.new(questrade_account).process
    end

    account.set_current_balance(anchor_balance, date: date) if anchor_balance

    account.broadcast_sync_complete
    Rails.logger.info "QuestradeAccount::Processor - Broadcast sync complete for account #{account.id}"

    {
      holdings_processed: questrade_account.raw_holdings_payload.present?,
      activities_processed: questrade_account.raw_activities_payload.present?
    }
  end

  private

    def update_account_balance(account)
      total = questrade_account.current_balance
      return if total.blank?

      cash = questrade_account.cash_balance || 0
      account.assign_attributes(
        balance: total,
        cash_balance: cash,
        currency: questrade_account.currency || account.currency
      )
      account.save!

      total
    end
end
