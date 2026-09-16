# frozen_string_literal: true

class QuestradeAccount::Processor
  include QuestradeAccount::DataHelpers

  attr_reader :questrade_account

  def initialize(questrade_account, publication_verifier: nil)
    @questrade_account = questrade_account
    @verifier = publication_verifier
  end

  def process
    QuestradeItem::LegacyAccess.with_account(questrade_account) do |fresh|
      @questrade_account = fresh
      process_admitted
    end
  end

  private

    def process_admitted
      account = questrade_account.current_account
      return unless account

      Rails.logger.info "QuestradeAccount::Processor - Processing account #{questrade_account.id} -> Sure account #{account.id}"

      # Anchor the account at its reported total (cash + holdings) and store the
      # primary-currency cash. Non-primary cash is surfaced as holdings below.
      expected = Account.instantiate(account.attributes.deep_dup)
      context = QuestradeItem::LegacyAccess.capture_context(questrade_account)
      QuestradeItem::LegacyAccess.with_publication(questrade_account, expected_account: expected,
        expected_context: context, verifier: @verifier) do |_fresh, financial|
        update_account_balance(financial)
        expected = Account.instantiate(financial.attributes.deep_dup)
      end

      if questrade_account.raw_holdings_payload.present? || questrade_account.non_primary_cash_entries.any?
        QuestradeAccount::HoldingsProcessor.new(questrade_account, publication_verifier: @verifier, expected_account: expected, expected_context: context).process
      end

      if questrade_account.raw_activities_payload.present?
        QuestradeAccount::ActivitiesProcessor.new(questrade_account, publication_verifier: @verifier, expected_account: expected, expected_context: context).process
      end

      QuestradeItem::LegacyAccess.with_publication(questrade_account, expected_account: expected,
        expected_context: context, verifier: @verifier) do |_fresh, financial|
        ActiveRecord.after_all_transactions_commit { financial.broadcast_sync_complete }
      end
      Rails.logger.info "QuestradeAccount::Processor - Broadcast sync complete for account #{account.id}"

      {
        holdings_processed: questrade_account.raw_holdings_payload.present?,
        activities_processed: questrade_account.raw_activities_payload.present?
      }
    end

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

      # Current-balance anchor = the reported total (cash + holdings). The value
      # is composed from the holdings + per-currency cash, not a made-up figure.
      result = account.set_current_balance(total)
      raise ActiveRecord::RecordNotSaved, "Questrade balance anchor was not saved" unless result.success?
    end
end
