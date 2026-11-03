# Restates the balances syncs recorded on a Sure account while it held more
# than its row's share of a trading account split by currency.
#
# Each sync sets a linked account's current balance, and on a new day the
# day before's is kept as a reconciliation that later days' balances are
# worked back from (see Account::CurrentBalanceManager). A combined account
# that becomes a currency's stocks account kept its cash, and other
# currencies, in those reconciliations; once the cash is in the cash account
# it would be counted there and again on every earlier day of the stocks
# account. One that becomes a cash account kept the positions in them.
#
# A stocks account's reconciliation is restated as the value of its
# currency's holdings that sync imported on that day, so its cash that day
# is nothing. Positions Sure doesn't import, such as options, were part of
# that cash too, and are left out of the restated day. One with no holdings
# imported that day, and every one of a cash account, whose cash on that day
# moomoo doesn't report, is removed: the days before the next one are then
# worked back from the account's own trades and cash movements.
#
# Only reconciliations a sync made from its current balance are touched,
# made while the account was linked to this row and before the split: they
# are the ones whose valuation changed kind after it was created. One entered
# by hand never does; one a sync made but changed by hand later is left too.
# A change to its notes alone can't be told from one to its amount, so that
# leaves it as well: its cash stays counted rather than the user's figure
# being overwritten.
# A reconciliation a sync recorded for a day before its anchor (a statement
# older than the current balance) can't be told from one entered by hand,
# and is left as it is.
class MoomooAccount::ReconciliationRestatement
  # How long after its valuation changed kind a reconciliation's entry may
  # last have been saved and still be the sync's.
  ROTATION_TOLERANCE = 1.second

  def initialize(moomoo_account)
    @moomoo_account = moomoo_account
  end

  def process
    return unless account && (moomoo_account.cash_role? || moomoo_account.stocks_role?)

    from = moomoo_account.account_provider&.created_at
    till = split_at
    return unless from && till && from < till

    changes = Hash.new(0)
    synced_reconciliations(from...till).includes(:entryable).find_each do |entry|
      change = restate(entry)
      changes[change] += 1 if change
    end
    log(changes) if changes.any?
  end

  private

    attr_reader :moomoo_account

    def account
      @account ||= moomoo_account.current_account
    end

    # When this row started holding only its share. A stocks row's cash row
    # is set up in the sync that splits its currency; a cash row that was
    # combined before saw the rest of its trading account's rows set up then.
    # A row set up in the split itself is linked after it, so nothing of its
    # account falls before.
    def split_at
      if moomoo_account.stocks_role?
        moomoo_account.cash_row_for(moomoo_account.currency)&.created_at
      else
        moomoo_account.sibling_currency_accounts.filter_map(&:created_at).min
      end
    end

    def synced_reconciliations(created)
      account.entries.valuations
        .joins("INNER JOIN valuations ON valuations.id = entries.entryable_id")
        .where(valuations: { kind: "reconciliation", created_at: created })
        .where("valuations.updated_at > valuations.created_at")
        .where("entries.updated_at <= valuations.updated_at + make_interval(secs => ?)", ROTATION_TOLERANCE.to_f)
    end

    # Returns what it did, if anything.
    def restate(entry)
      return if entry.protected_from_sync?

      value = holdings_value(entry.date) if moomoo_account.stocks_role?
      if value.nil?
        entry.destroy!
        :removed
      elsif entry.amount != value
        entry.update!(amount: value)
        # Keeps it recognisable as the sync's on the next pass.
        entry.entryable.touch
        :restated
      end
    end

    def holdings_value(date)
      holdings = account.holdings.where(date: date, currency: account.currency).where.not(account_provider_id: nil)
      holdings.sum(:amount) if holdings.exists?
    end

    def log(changes)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooAccount::ReconciliationRestatement - restated the #{moomoo_account.role} account's balances from before the split by currency",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, **changes }
      )
    end
end
