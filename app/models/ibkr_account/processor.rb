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
      result = nil

      # One lock across the whole of it. Which statement the account follows is
      # decided by the anchor's date, and a sync running beside this one can
      # move that anchor between any two of these writes -- so the currency,
      # the anchor and the cash split are settled together, and follow the same
      # statement. The manager is called directly: the Anchorable wrapper
      # queues the sync, which belongs after the lock is released.
      account.with_lock do
        manager = Account::CurrentBalanceManager.new(account)

        # The currency is written ahead of the anchor so the anchor is made in
        # it, but only when this statement is the one the anchor will follow:
        # an older one leaves the balance where it is, and the cached figures
        # must keep the denomination they were written in. Rolled back below
        # with everything else if the write fails.
        if ibkr_account.currency != account.currency && !statement_behind_anchor?(manager)
          account.update!(currency: ibkr_account.currency)
        end

        # Dated to the statement, not to today: the NAV is as of IBKR's report
        # date and the holdings imported beside it carry that same date.
        # Anchoring it to today instead pairs one day's NAV with the next day's
        # prices, and the cash plug absorbs the difference -- a phantom balance
        # the size of whatever the holdings moved that day, on every day of the
        # account's history.
        result = manager.set_current_balance(total_balance, date: balance_date)

        # The manager rescues and reports failure through its result, and its
        # own lock joined this transaction rather than opening one -- so what
        # it wrote before failing (an anchor already rotated into a
        # reconciliation, a reconciliation saved before its pledge failed)
        # would commit with the currency. Nothing of this statement may stay.
        raise ActiveRecord::Rollback unless result.success?

        # The cached balance and its cash split are what the account is worth
        # now, and set_current_balance owns the first of them. A statement
        # older than the anchor describes a day gone by, so it moves neither.
        account.update!(cash_balance: cash_balance) unless result.historical?
      end

      if result.success?
        account.sync_later
      else
        # set_current_balance rescues and reports through its result, so a failed
        # write is otherwise silent. Captured rather than raised, as the anchor
        # repair below is: broadcast_sync_complete still has to run.
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "error",
          message: "Failed to set the current balance: #{result.error}",
          source: self.class.name,
          provider_key: "ibkr",
          account_provider: ibkr_account.account_provider,
          family: ibkr_account.ibkr_item&.family,
          metadata: { report_date: ibkr_account.report_date&.to_s, balance_date: balance_date.to_s }
        )
      end

      result
    end

    def statement_behind_anchor?(manager)
      manager.has_current_anchor? && manager.current_date > balance_date
    end

    def balance_date
      date = ibkr_account.report_date
      return Date.current if date.blank? || date > Date.current

      date
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
