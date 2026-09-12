class Account::CurrentBalanceManager
  InvalidOperation = Class.new(StandardError)

  Result = Struct.new(:success?, :changes_made?, :error, keyword_init: true)

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

  def set_current_balance(balance)
    if account.linked?
      result = set_current_balance_for_linked_account(balance)
    else
      result = set_current_balance_for_manual_account(balance)
    end

    # Update cache field so changes appear immediately to the user
    account.update!(balance: balance)

    result
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
    # Processors write the anchor AFTER importing the sync's transactions, so the ledger for
    # the gap since the standing anchor is complete and we can judge it now:
    #
    #   * the ledger explains the move -> the old anchor just moves forward in place
    #   * it doesn't -> the provider knew something the ledger doesn't, so the old anchor is
    #     kept as a reconciliation waypoint (#1492, #1484) and a fresh anchor created for today
    def set_current_balance_for_linked_account(balance)
      changes_made = false

      ActiveRecord::Base.transaction do
        anchor = current_anchor_valuation

        if anchor && anchor.entry.date < Date.current && !ledger_explains?(anchor.entry, balance)
          anchor.update!(kind: "reconciliation")
          anchor.entry.update!(name: Valuation.build_reconciliation_name(account.accountable_type))
          Rails.logger.info("[AnchorRotation] Converted current_anchor to reconciliation for account #{account.id}, date=#{anchor.entry.date}, entry_id=#{anchor.entry.id}")
          anchor = nil
        end

        if anchor
          changes_made = update_current_anchor(balance)
        else
          create_current_anchor(balance)
          changes_made = true
        end
      end

      Result.new(success?: true, changes_made?: changes_made, error: nil)
    end

    # Legacy data can still carry more than one anchor row, and the query has no ORDER BY,
    # so pick the newest deterministically. Ids are random UUIDs: a last-resort tiebreak only.
    def current_anchor_valuation
      @current_anchor_valuation ||=
        account.valuations.current_anchor.includes(:entry).max_by { |v| [ v.entry.date, v.entry.created_at, v.entry.id ] }
    end

    # True when imported transactions and trades account for the entire move between the
    # standing anchor and the reading we're about to write.
    #
    # Sign convention is Balance::ForwardCalculator#signed_entry_flows: a positive entry
    # amount decreases an asset and increases a liability. One sum covers any gap length.
    #
    # The window is inclusive at both ends. The lower end matters because readings are taken
    # mid-day, so entries dated on the anchor's own date can post after it was taken. On that
    # date only, entries that predate the anchor's last write are skipped: the provider could
    # already see them, so after an in-place move they are inside the stored amount and
    # counting them again would make an explained move look unexplained. `updated_at` is the
    # watermark (saved exactly when amount and/or date change) and `>` excludes entries
    # imported in the same sync cycle as the anchor write, which share its timestamp.
    #
    # Restricted to :cash accounts: an :investment total moves with market prices, and
    # :non_cash accounts are valuation-driven, so the identity means nothing for either.
    def ledger_explains?(older_entry, new_balance)
      return false unless account.balance_type == :cash

      # The identity below adds account-currency flows to the anchor's own amount, so an anchor
      # written before a provider corrected the account's currency mixes units. Moving it forward
      # would not repair that: `update_current_anchor` only ever rewrites amount and date.
      return false unless older_entry.currency == account.currency

      # Same set the balance calculators see (Balance::SyncCache#converted_entries and
      # #get_entries): transactions and trades only, pending and split parents out,
      # `excluded` entries still counted.
      flows = account.entries
        .excluding_pending
        .excluding_split_parents
        .where(date: older_entry.date..Date.current)
        .where.not(entryable_type: "Valuation")
        .where("entries.date > :anchor_date OR entries.created_at > :anchor_written_at",
               anchor_date: older_entry.date, anchor_written_at: older_entry.updated_at)
        .pluck(:currency, :amount)

      # A plain sum would silently add EUR to USD; bail rather than guess an FX rate.
      return false unless flows.all? { |currency, _| currency == account.currency }

      net = flows.sum { |_, amount| amount }
      expected = older_entry.amount + (account.asset? ? -net : net)

      (expected - new_balance).abs <= BigDecimal("0.01")
    end

    def create_current_anchor(balance)
      account.entries.create!(
        date: Date.current,
        name: Valuation.build_current_anchor_name(account.accountable_type),
        amount: balance,
        currency: account.currency,
        entryable: Valuation.new(kind: "current_anchor")
      )

      # Clear memoized value so it picks up the new anchor on next access.
      @current_anchor_valuation = nil
    end

    def update_current_anchor(balance)
      changes_made = false

      # Update associated entry attributes
      entry = current_anchor_valuation.entry

      if entry.amount != balance
        entry.amount = balance
        changes_made = true
      end

      if entry.date != Date.current
        entry.date = Date.current
        changes_made = true
      end

      entry.save! if entry.changed?

      changes_made
    end
end
