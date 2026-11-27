# Where a StashAway import into a Sure account begins, and the balance it
# begins from.
#
# An account linked with entries from other sources keeps them: the import
# starts the day after the last one and measures its first month's return
# from the account's own balance the day before. An account with none gets
# the whole history.
class StashawayAccount::ImportStart
  def initialize(stashaway_account, account)
    @stashaway_account = stashaway_account
    @account = account
  end

  # nil for the whole history. A scheduled (future-dated) entry is not
  # history yet, as for the account's balances: counted, it would put the
  # start after today, where no balance is known to begin from.
  def date
    entries_from_elsewhere.where(date: ..Date.current).maximum(:date)&.next_day
  end

  # The account's balance the day before `start`: the one fixed when it was
  # first read (StashawayAccount#import_base), else the account's own
  # entries run forward to that day, as a manual account's balances are.
  # The stored balances are not read: once linked, the account derives them
  # backwards from its anchor, and before the first import that only
  # restates a cached balance that may predate its latest rows. nil when
  # the account has no balance on that day; 0 for the whole history.
  def base_for(start)
    return BigDecimal("0") unless start
    return stashaway_account.import_base if stashaway_account.import_base

    Balance::ForwardCalculator.new(account).calculate.find { |balance| balance.date == start.prev_day }&.balance
  end

  private

    attr_reader :stashaway_account, :account

    # Every entry not imported from StashAway, but for the ones that are not
    # history: the provider's current-balance anchor, an opening anchor of
    # zero (the placeholder a new account gets) and split children, whose
    # parent already counts.
    def entries_from_elsewhere
      account.entries
        .where("entries.source IS DISTINCT FROM ?", StashawayAccount::SOURCE)
        .where(parent_entry_id: nil)
        .where.not(id: placeholder_anchor_entry_ids)
    end

    def placeholder_anchor_entry_ids
      account.entries
        .joins("INNER JOIN valuations ON valuations.id = entries.entryable_id AND entries.entryable_type = 'Valuation'")
        .where("valuations.kind = 'current_anchor' OR (valuations.kind = 'opening_anchor' AND entries.amount = 0)")
        .select(:id)
    end
end
