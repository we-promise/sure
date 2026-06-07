class Account::ReconciliationManager
  attr_reader :account

  def initialize(account)
    @account = account
  end

  # Reconciles balance by creating a Valuation entry. If existing valuation is provided, it will be updated instead of creating a new one.
  def reconcile_balance(balance:, date: Date.current, dry_run: false, existing_valuation_entry: nil)
    old_balance_components = old_balance_components(reconciliation_date: date, existing_valuation_entry: existing_valuation_entry)
    prepared_valuation = prepare_reconciliation(balance, date, existing_valuation_entry)
    # Captured before save!: the amount this valuation already had on disk
    # (nil when this reconciliation creates it). See valuation_contribution.
    prior_valuation_amount = prepared_valuation.amount_in_database

    unless dry_run
      prepared_valuation.save!
      contribution = valuation_contribution(prepared_valuation, prior_valuation_amount, old_balance_components)
      GoalPledge::Reconciler.new(prepared_valuation, valuation_delta: contribution).run
    end

    ReconciliationResult.new(
      success?: true,
      old_cash_balance: old_balance_components[:cash_balance],
      old_balance: old_balance_components[:balance],
      new_cash_balance: derived_cash_balance(date: date, total_balance: prepared_valuation.amount),
      new_balance: prepared_valuation.amount,
      error_message: nil
    )
  rescue => e
    ReconciliationResult.new(
      success?: false,
      error_message: e.message
    )
  end

  private
    # Returns before -> after OR error message
    ReconciliationResult = Struct.new(
      :success?,
      :old_cash_balance,
      :old_balance,
      :new_cash_balance,
      :new_balance,
      :error_message,
      keyword_init: true
    )

    # Contribution recorded by this reconciliation: how much the balance moved
    # vs. the prior balance. This (not the full new balance) is what a
    # manual_save GoalPledge matches against.
    #
    # The prior balance is resolved in freshness order:
    #   1. The valuation's own pre-save amount, when this reconciliation
    #      updates an existing valuation. The balances table recomputes
    #      asynchronously (sync_later fires after this manager returns), so a
    #      same-date re-reconcile racing that sync would otherwise read the
    #      pre-first-reconcile row and over- or under-state the delta — an
    #      overstated delta could wrongly close a larger pledge, which never
    #      self-heals. The valuation's own prior amount is immune to that
    #      race, and once the sync lands the two sources are identical (the
    #      valuation anchors that date's end_balance).
    #   2. The balances-table row for the date (first reconcile on a date).
    #      This can still be stale in one residual window: a reconcile on a
    #      NEW date racing the previous date's pending sync reads a
    #      carried-forward row. A missed match self-heals on the next re-save
    #      — the pledge stays open and retryable until `expires_at`, and the
    #      date/amount tolerance in GoalPledge#matches? accepts the retry.
    #   3. 0, for a brand-new account with no balance record yet, so the
    #      first reconciliation's full balance is its contribution.
    #
    # The delta is only ever consumed for goal-linked accounts, which Goal
    # validates to be Depository assets (Goal#linked_accounts_must_be_depository).
    # Balances there are positive, so a save (deposit) is a positive delta and
    # the reconciler's positive-delta guard is correct. There is no liability
    # sign concern: a credit-card/loan paydown can't reach pledge matching
    # because no manual_save pledge can be attached to a non-depository account.
    def valuation_contribution(valuation, prior_valuation_amount, old_balance_components)
      prior_balance = prior_valuation_amount || old_balance_components[:balance] || 0
      valuation.amount.to_d - prior_balance.to_d
    end

    def prepare_reconciliation(balance, date, existing_valuation)
      valuation_record = existing_valuation ||
                         account.entries.valuations.find_by(date: date) || # In case of conflict, where existing valuation is not passed as arg, but one exists
                         account.entries.build(
                                  name: Valuation.build_reconciliation_name(account.accountable_type),
                                  entryable: Valuation.new(kind: "reconciliation")
                                )

      valuation_record.assign_attributes(
        date: date,
        amount: balance,
        currency: account.currency
      )

      valuation_record
    end

    def derived_cash_balance(date:, total_balance:)
      balance_components_for_reconciliation_date = get_balance_components_for_date(date)

      return nil unless balance_components_for_reconciliation_date[:balance] && balance_components_for_reconciliation_date[:cash_balance]

      # We calculate the existing non-cash balance, which for investments would represents "holdings" for the date of reconciliation
      # Since the user is setting "total balance", we have to subtract the existing non-cash balance from the total balance to get the new cash balance
      existing_non_cash_balance = balance_components_for_reconciliation_date[:balance] - balance_components_for_reconciliation_date[:cash_balance]

      total_balance - existing_non_cash_balance
    end

    def old_balance_components(reconciliation_date:, existing_valuation_entry: nil)
      if existing_valuation_entry
        get_balance_components_for_date(existing_valuation_entry.date)
      else
        get_balance_components_for_date(reconciliation_date)
      end
    end

    def get_balance_components_for_date(date)
      balance_record = account.balances.find_by(date: date, currency: account.currency)

      {
        cash_balance: balance_record&.end_cash_balance,
        balance: balance_record&.end_balance
      }
    end
end
