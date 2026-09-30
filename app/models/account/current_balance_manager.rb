class Account::CurrentBalanceManager
  InvalidOperation = Class.new(StandardError)

  # `historical?` marks the statement as older than the anchor: it was recorded
  # behind the current balance, which nothing about the account as it stands now
  # should follow.
  Result = Struct.new(:success?, :changes_made?, :error, :historical?, keyword_init: true)

  def initialize(account)
    @account = account
  end

  def has_current_anchor?
    current_anchor_valuation.present?
  end

  # Our system should always make sure there is a current anchor, and that it is up to date.
  # The fallback is provided for backwards compatibility, but should not be relied on since account.balance is a "cached/derived" value.
  def current_balance
    if current_anchor_valuation
      current_anchor_valuation.entry.amount
    else
      Rails.logger.warn "No current balance anchor found for account #{account.id}. Using cached balance instead, which may be out of date."
      account.balance
    end
  end

  def current_date
    if current_anchor_valuation
      current_anchor_valuation.entry.date
    else
      Date.current
    end
  end

  # Stage provider totals for cash capture while manual totals retain reconciliation.
  # `date` is the day the balance describes, for a provider whose figures are
  # as of a statement rather than of this moment. It only applies to a linked
  # account: a manual one has no statement, and its strategies reconcile against
  # today by design.
  def set_current_balance(balance, date: nil, provider_balance: false)
    @provider_balance = provider_balance && account.accounting_start_date.present?
    if @provider_balance || !account.manual_accounting?
      set_current_balance_for_linked_account(balance, date || Date.current)
    else
      result = set_current_balance_for_manual_account(balance)

      # Update cache field so changes appear immediately to the user
      account.update!(balance: balance)

      result
    end
  rescue => e
    Result.new(success?: false, changes_made?: false, error: e.message)
  end

  private
    attr_reader :account

    def opening_balance_manager
      @opening_balance_manager ||= Account::OpeningBalanceManager.new(account)
    end

    def reconciliation_manager
      @reconciliation_manager ||= Account::ReconciliationManager.new(account)
    end

    # Manual accounts do not manage the `current_anchor` valuation (otherwise, user would need to continually update it, which is bad UX)
    # Instead, we use a combination of "auto-update strategies" to set the current balance according to the user's intent.
    #
    # The "auto-update strategies" are:
    # 1. Value tracking - If the account has a reconciliation already, we assume they are tracking the account value primarily with reconciliations, so we append a new one
    # 2. Transaction adjustment - If the account doesn't have recons, we assume user is tracking with transactions, so we adjust the opening balance with a delta until it
    #                             gets us to the desired balance. This ensures we don't append unnecessary reconciliations to the account, which "reset" the value from that
    #                             date forward (not user's intent).
    #
    # For more documentation on these auto-update strategies, see the test cases.
    def set_current_balance_for_manual_account(balance)
      # If we're dealing with a cash account that has no reconciliations, use "Transaction adjustment" strategy (update opening balance to "back in" to the desired current balance)
      if account.balance_type == :cash && account.valuations.reconciliation.empty?
        adjust_opening_balance_with_delta(new_balance: balance, old_balance: account.balance)
      else
        existing_reconciliation = account.entries.valuations.where.not(entryable_id: Valuation.cash_anchor.select(:id)).find_by(date: Date.current)

        result = reconciliation_manager.reconcile_balance(balance: balance, date: Date.current, existing_valuation_entry: existing_reconciliation)

        # Normalize to expected result format
        Result.new(success?: result.success?, changes_made?: true, error: result.error_message)
      end
    end

    def adjust_opening_balance_with_delta(new_balance:, old_balance:)
      delta = new_balance - old_balance

      result = opening_balance_manager.set_opening_balance(balance: account.opening_anchor_balance + delta)

      # Normalize to expected result format
      Result.new(success?: result.success?, changes_made?: true, error: result.error)
    end

    # Linked accounts manage "current balance" via the special `current_anchor` valuation.
    # This is NOT a user-facing feature, and is primarily used in "processors" while syncing
    # linked account data (e.g. via Plaid)
    #
    # Before overwriting a stale (previous-day) current_anchor, we convert it to a
    # reconciliation valuation. This preserves the API-reported balance as a historical
    # waypoint that the ReverseCalculator uses for more accurate balance history.
    def set_current_balance_for_linked_account(balance, date)
      changes_made = false
      error = nil
      historical = false

      # Locked, with the anchor re-read inside it: everything below turns on
      # which side of the anchor's date this statement falls, and a sync running
      # beside this one can move that anchor between the read and the write.
      account.with_lock do
        @current_anchor_valuation = nil

        if anchor_newer_than?(date)
          # A statement older than the anchor already holds is a correction to a
          # day gone by, not the balance now. It is recorded on its own date,
          # the newer anchor is left where it stands, and the cached balance --
          # which is the balance now -- is not touched.
          result = record_historical_balance(balance, date)
          changes_made = result.changes_made?
          error = result.error
          historical = true
        else
          # Only a statement that moves the balance forward leaves the previous
          # anchor behind as a reconciliation. One carrying the anchor's own date
          # is that same anchor restated, so it is updated rather than duplicated.
          preserve_anchor_as_reconciliation_if_stale(date) if current_anchor_valuation

          # Re-check: the memoized value was cleared if the anchor was converted
          if current_anchor_valuation
            changes_made = update_current_anchor(balance, date)
          else
            create_current_anchor(balance, date)
            changes_made = true
          end

          # Update cache field so changes appear immediately to the user
          account.update!(balance: balance) unless @provider_balance
        end
      end

      Result.new(success?: error.nil?, changes_made?: changes_made, error: error, historical?: historical)
    end

    def anchor_newer_than?(date)
      current_anchor_valuation.present? && current_anchor_valuation.entry.date > date
    end

    def record_historical_balance(balance, date)
      entry = account.entries.valuations.where.not(entryable_id: Valuation.cash_anchor.select(:id)).find_by(date: date)
      if @provider_balance
        entry ||= account.entries.build(
          name: Valuation.build_reconciliation_name(account.accountable_type),
          entryable: Valuation.new(kind: "reconciliation")
        )
        entry.source = "provider_balance"
      end

      result = reconciliation_manager.reconcile_balance(
        balance: balance,
        date: date,
        existing_valuation_entry: entry
      )

      Result.new(success?: result.success?, changes_made?: result.success?, error: result.error_message)
    end

    def current_anchor_valuation
      @current_anchor_valuation ||= account.valuations.current_anchor.includes(:entry).first
    end

    # If the existing current_anchor is from a previous day, convert it to a
    # reconciliation before overwriting. This accumulates a chain of API-reported
    # balance waypoints over time without creating extra entries per sync.
    #
    # Same-day updates are left in place (no extra reconciliations on repeated syncs).
    def preserve_anchor_as_reconciliation_if_stale(date)
      entry = current_anchor_valuation.entry
      return if entry.date == date # Same-day update — nothing to preserve

      current_anchor_valuation.update!(kind: "reconciliation")
      entry.update!(name: Valuation.build_reconciliation_name(account.accountable_type))
      Rails.logger.info("[AnchorRotation] Converted current_anchor to reconciliation for account #{account.id}, date=#{entry.date}, entry_id=#{entry.id}")

      # Clear memoized value so the next check creates a fresh current_anchor.
      # The chained scope (.current_anchor.first) always issues a fresh SQL query,
      # so we don't need to reload the full association.
      @current_anchor_valuation = nil
    end

    # Tag imported totals so shared materialization can isolate their reported cash.
    def create_current_anchor(balance, date)
      account.entries.create!(
        date: date,
        name: Valuation.build_current_anchor_name(account.accountable_type),
        amount: balance,
        currency: account.currency,
        source: @provider_balance ? "provider_balance" : nil,
        entryable: Valuation.new(kind: "current_anchor")
      )

      # Clear memoized value so it picks up the new anchor on next access.
      @current_anchor_valuation = nil
    end

    # Update the total anchor without prematurely replacing a mixed account's balance.
    def update_current_anchor(balance, date)
      changes_made = false

      # Update associated entry attributes
      entry = current_anchor_valuation.entry
      entry.source = @provider_balance ? "provider_balance" : nil

      if entry.amount != balance
        entry.amount = balance
        changes_made = true
      end

      if entry.date != date
        entry.date = date
        changes_made = true
      end

      entry.save! if entry.changed?

      changes_made
    end
end
