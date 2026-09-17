# Finds money that has left a goal's accounts without anyone saying where it
# went.
#
# Goals never read transactions — `current_balance` is a stock, summed from
# account balances — so an outflow reaches them only as a smaller number, with
# no idea which goal it belonged to. `consume!` closes that gap but only if the
# user thinks to declare it, which is the same problem the goal page had before
# the reserve insight: the app knows and does not say.
#
# This is the *pull* half of what `GoalPledge` does for money coming in. The
# pledge asks first and matches later; here there is nothing to promise, so the
# outflow is surfaced after the fact and the user attributes it — or does not.
class Goal::WithdrawalDetector
  # Below this an attribution is more friction than it is worth: a goal-backed
  # savings account sees card-sized outflows that nobody wants to file.
  #
  # Same known limitation as `IdleCashGenerator::MIN_BALANCE`: a flat figure in
  # family-currency units, tuned for dollar/euro-scale currencies.
  MIN_AMOUNT = 100

  # A window, not all history. An outflow nobody attributed in three months is
  # one nobody is going to, and asking forever turns the panel into a chore.
  LOOKBACK_DAYS = 90

  # `accounts:` narrows the search to what the caller may see. A goal can be
  # backed by an account private to another family member, and its outflows are
  # that member's business — surfacing them here would name the account, its
  # spending and roughly its size to someone with no access to it. Defaults to
  # every linked account for callers with no viewer to speak for (jobs, tests).
  def initialize(goal, accounts: nil)
    @goal = goal
    @accounts = accounts
  end

  # Outflows on this goal's accounts that nothing has claimed yet, newest
  # first. Empty for a goal that cannot consume — a reserve is drawn down and
  # refilled rather than spent, and its shortfall already says so on its own.
  def unattributed_outflows(limit: 3)
    return Entry.none unless goal.one_off?
    # A released goal has handed its accounts back, so an outflow on one of
    # them is no longer evidence about this goal — offering it would invite the
    # user to write spending into a history that is closed. `consume!` refuses
    # these too; the panel simply should not ask in the first place.
    return Entry.none unless goal.active?
    return Entry.none if accounts.empty?

    candidates.limit(limit)
  end

  private
    attr_reader :goal

    def accounts
      @accounts ||= goal.linked_accounts
    end

    def candidates
      Entry
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(account_id: accounts.map(&:id))
        .where(excluded: false)
        .where(date: LOOKBACK_DAYS.days.ago.to_date..Date.current)
        # In Sure an inflow carries a NEGATIVE amount, so an outflow is the
        # positive side. Reading this the other way round would offer to
        # attribute the user's deposits as spending.
        .where("entries.amount >= ?", MIN_AMOUNT)
        .where("transactions.extra -> 'goal' ->> 'consumed_goal_id' IS NULL")
        # A provisional charge can still be reversed or replaced by its posted
        # form. Attributing one leaves the goal consumed for a transaction that
        # no longer exists, while the posted twin arrives unstamped and gets
        # offered all over again.
        #
        # `pending_providers_sql` is built to be appended to an existing WHERE,
        # so it leads with AND; the rest of its clauses chain correctly once
        # that first one is dropped.
        .where(Transaction.pending_providers_sql("transactions").sub(/\AAND /, ""))
        .order(date: :desc, id: :desc)
    end
end
