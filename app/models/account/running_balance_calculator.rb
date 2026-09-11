class Account::RunningBalanceCalculator
  # Computes a true per-entry running balance for a set of entries, instead
  # of the coarser per-day Balance-table lookup (which gives every entry on
  # the same calendar day the same end-of-day figure).
  #
  # Approach: for each account, anchor on the prior day's persisted end
  # balance (the authoritative `Balance` row), then walk that day's entries
  # forward in `Entry.chronological` order, applying the same signed-flow
  # rule used by `Balance::ForwardCalculator#signed_entry_flows` so the
  # running totals stay consistent with `account.balance`. A `Valuation`
  # entry resets the running total to its absolute amount (it isn't a flow),
  # matching how the day-level calculator treats valuations.
  #
  # Known limitation: for accounts with a non-cash component (investment /
  # crypto accounts with holdings), the non-cash portion of the balance is
  # priced from market value on a daily basis (see Balance::BaseCalculator),
  # not attributable to any single trade. Distributing that day's holdings
  # value change across individual trades would be a fabricated number, so
  # for those accounts we intentionally fall back to the existing per-day
  # balance instead of a misleading per-transaction figure.
  #
  #   Account::RunningBalanceCalculator.new(entries).running_balances
  #   # => { entry_id => Money, ... }
  def initialize(entries)
    @entries = entries.to_a
  end

  def running_balances
    return {} if @entries.empty?

    result = {}

    entries_by_account.each do |account, account_entries|
      if account.supports_trades?
        result.merge!(per_day_balances(account, account_entries))
      else
        result.merge!(per_entry_balances(account, account_entries))
      end
    end

    result
  end

  private
    attr_reader :entries

    def entries_by_account
      @entries.group_by(&:account)
    end

    # Fallback for accounts where the non-cash (holdings) balance can't be
    # meaningfully attributed to a single entry — same per-day lookup that
    # was used previously.
    def per_day_balances(account, account_entries)
      dates = account_entries.map(&:date).uniq
      balances_by_date = account.balances.where(date: dates, currency: account.currency).index_by(&:date)

      account_entries.each_with_object({}) do |entry, hash|
        bal = balances_by_date[entry.date]
        hash[entry.id] = bal ? bal.end_balance_money : Money.new(0, account.currency)
      end
    end

    def per_entry_balances(account, account_entries)
      dates = account_entries.map(&:date).uniq.sort
      min_date = dates.first
      max_date = dates.last

      seed_balance = account.balances
        .where(currency: account.currency)
        .where("date < ?", min_date)
        .order(date: :desc)
        .first
        &.end_balance
        .to_f

      running_total = seed_balance
      result = {}

      # Walk every account entry (not just the requested ones) in chronological
      # order from the seed date forward, so intra-day ordering and prior
      # same-day entries are correctly reflected — but only record results for
      # the entries we were actually asked about. Stop once we're past the
      # last requested date (split children always share their parent's date,
      # per validation), so a deep page of old entries doesn't force a walk
      # through the account's entire subsequent history.
      requested_ids = account_entries.map(&:id).to_set

      account.entries
        .excluding_pending
        .excluding_split_parents
        .where(date: min_date..max_date)
        .chronological
        .includes(:entryable)
        .each do |entry|
          break if entry.date > max_date

          if entry.entryable_type == "Valuation"
            running_total = converted_amount(entry, account)
          else
            running_total += signed_flow(account, entry)
          end

          current_balance = Money.new(running_total, account.currency)
          result[entry.id] = current_balance if requested_ids.include?(entry.id)

          # Split-parent rows don't carry their own flow (their children do,
          # via excluding_split_parents above), but they're rendered as their
          # own row — surface the running total as of the last child applied,
          # so the group reads as a single combined transaction.
          if entry.parent_entry_id.present? && requested_ids.include?(entry.parent_entry_id)
            result[entry.parent_entry_id] = current_balance
          end
        end

      # Any requested entries that got filtered out by excluding_pending
      # (e.g. a pending transaction) or that had no children applied (an
      # empty split parent) won't have a computed value — fall back to the
      # last known running total.
      account_entries.each do |entry|
        result[entry.id] ||= Money.new(running_total, account.currency)
      end

      result
    end

    # Mirrors Balance::ForwardCalculator#signed_entry_flows, applied per entry
    # rather than summed over a whole day.
    def signed_flow(account, entry)
      amount = converted_amount(entry, account)
      account.asset? ? -amount : amount
    end

    # Entries can be recorded in a currency other than the account's (see
    # Balance::SyncCache#converted_entries) — convert before folding into the
    # running total so it stays consistent with the account's own currency.
    def converted_amount(entry, account)
      return entry.amount if entry.currency == account.currency

      custom_rate = entry.entryable.exchange_rate if entry.entryable.respond_to?(:exchange_rate)
      entry.amount_money.exchange_to(account.currency, date: entry.date, custom_rate: custom_rate).amount
    rescue Money::ConversionError
      entry.amount
    end
end
