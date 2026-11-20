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

  def current_anchor_entry
    current_anchor_valuation&.entry
  end

  # The sum of the imported transactions and trades the anchor has not seen yet,
  # through `date`, as entry amounts. Nil when that can't be judged: the account
  # isn't :cash, or a flow or the anchor is in another currency.
  def ledger_net_since(older_entry, date)
    return unless account.balance_type == :cash
    return unless older_entry.currency == account.currency

    # Ignore entries the anchor already included: its own timestamp is the watermark.
    # A split child inherits its parent's timestamp; the parent was the flow the anchor
    # could have seen, and the child rows are created later by the split.
    flows = account.entries
      .excluding_pending
      .excluding_split_parents
      .where(date: older_entry.date..date)
      .where.not(entryable_type: "Valuation")
      .where(
        "entries.date > :anchor_date OR " \
        "COALESCE((SELECT pe.created_at FROM entries pe WHERE pe.id = entries.parent_entry_id), entries.created_at) > :anchor_written_at",
        anchor_date: older_entry.date, anchor_written_at: older_entry.updated_at
      )
      .pluck(:currency, :amount)

    return unless flows.all? { |currency, _| currency == account.currency }

    flows.sum { |_, amount| amount }
  end

  def current_date
    if current_anchor_valuation
      current_anchor_valuation.entry.date
    else
      Date.current
    end
  end

  # `date` is the day the balance describes, for a provider whose figures are
  # as of a statement rather than of this moment. It only applies to a linked
  # account: a manual one has no statement, and its strategies reconcile against
  # today by design.
  def set_current_balance(balance, date: nil, reuse_explained_anchor: true)
    if account.linked?
      set_current_balance_for_linked_account(
        balance,
        date || Date.current,
        reuse_explained_anchor: reuse_explained_anchor
      )
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
        existing_reconciliation = account.entries.valuations.find_by(date: Date.current)

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
    # linked account data (e.g. via Plaid).
    #
    # A stale anchor the imported ledger explains moves forward in place. Otherwise it is
    # preserved as a reconciliation waypoint (#1492, #1484). Gated on
    # BALANCE_REUSE_EXPLAINED_ANCHOR; when off, every stale anchor is preserved.
    def set_current_balance_for_linked_account(balance, date, reuse_explained_anchor: true)
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
          anchor = current_anchor_valuation

          if anchor && anchor.entry.date < date &&
              (!reuse_explained_anchor || !ledger_explains?(anchor.entry, balance, date))
            preserve_anchor_as_reconciliation_if_stale(date)
            anchor = nil
          end

          if anchor
            changes_made = update_current_anchor(balance, date)
          else
            create_current_anchor(balance, date)
            changes_made = true
          end

          # Update cache field so changes appear immediately to the user
          account.update!(balance: balance)
        end
      end

      Result.new(success?: error.nil?, changes_made?: changes_made, error: error, historical?: historical)
    end

    def anchor_newer_than?(date)
      current_anchor_valuation.present? && current_anchor_valuation.entry.date > date
    end

    def record_historical_balance(balance, date)
      result = reconciliation_manager.reconcile_balance(
        balance: balance,
        date: date,
        existing_valuation_entry: account.entries.valuations.find_by(date: date)
      )

      Result.new(success?: result.success?, changes_made?: result.success?, error: result.error_message)
    end

    # Legacy data can still carry more than one anchor row, and the query has no ORDER BY,
    # so pick the newest deterministically. Ids are random UUIDs: a last-resort tiebreak only.
    def current_anchor_valuation
      @current_anchor_valuation ||=
        account.valuations.current_anchor.includes(:entry).max_by { |v| [ v.entry.date, v.entry.created_at, v.entry.id ] }
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

    # True when the imported transactions and trades account for the entire move
    # between the standing anchor and the new reading. Only meaningful for :cash.
    def ledger_explains?(older_entry, new_balance, date)
      return false unless Rails.configuration.x.balance.reuse_explained_anchor

      net = ledger_net_since(older_entry, date)
      return false if net.nil?

      expected = older_entry.amount + (account.asset? ? -net : net)
      tolerance = BigDecimal(Money::Currency.new(account.currency).step.to_s)

      (expected - new_balance).abs <= tolerance
    end

    def create_current_anchor(balance, date)
      account.entries.create!(
        date: date,
        name: Valuation.build_current_anchor_name(account.accountable_type),
        amount: balance,
        currency: account.currency,
        entryable: Valuation.new(kind: "current_anchor")
      )

      # Clear memoized value so it picks up the new anchor on next access.
      @current_anchor_valuation = nil
    end

    def update_current_anchor(balance, date)
      changes_made = false

      # Update associated entry attributes
      entry = current_anchor_valuation.entry

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
