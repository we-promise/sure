# Syncs before liability balances were negated stored a card's readings as
# SnapTrade sends them: owed as negative, credit as positive. Each day's
# reading stays behind as a reconciliation, and the balance history resets to
# every one of them, so a wrong-signed reading left anywhere shows as a jump
# that never happened.
#
# Such readings can only be there on an account's first sync since the fix,
# so this runs once per account and is then marked done, under a lock so
# overlapping syncs can't both turn them. The ledger decides each reading's
# sign, newest first: a later reading less what was imported in between is
# the balance on the earlier one's date, and a reading of the opposite sign is
# turned around. A loan's balance doesn't move with its transactions, so for
# one the later reading itself is that balance.
#
# Only readings a sync could have written are candidates: those recorded since
# SnapTrade was linked and never edited. A reading entered by hand in Sure's
# signs already agrees with the ledger and is left as it is.
class SnaptradeAccount::LiabilitySignRepair
  def initialize(snaptrade_account, account)
    @snaptrade_account = snaptrade_account
    @account = account
  end

  # `balance` is the current reading in Sure's signs, as of `date`.
  def run(balance, date)
    return if snaptrade_account.liability_signs_fixed_at?

    SnaptradeAccount.transaction do
      locked = SnaptradeAccount.lock.find(snaptrade_account.id)
      next if locked.liability_signs_fixed_at?

      repair_readings(balance, date) if account.liability?

      locked.update_columns(liability_signs_fixed_at: Time.current)
    end
  end

  private
    attr_reader :snaptrade_account, :account

    def repair_readings(balance, date)
      flows = Account::LedgerFlows.new(account)
      later_balance = balance
      later_date = date

      readings.each do |reading|
        net = account.balance_type == :non_cash ? 0 : flows.net_since(reading, later_date)
        break if net.nil?

        derived = later_balance - net
        if reading.amount.nonzero? && derived.nonzero? && reading.amount.positive? != derived.positive?
          # Leaves updated_at alone: it marks which flows the reading had seen.
          reading.update_columns(amount: -reading.amount)
        end

        later_balance = reading.amount
        later_date = reading.date
      end
    end

    def readings
      linked_at = snaptrade_account.account_provider&.created_at
      return Entry.none unless linked_at

      account.entries
        .where(entryable_type: "Valuation", entryable_id: Valuation.where(kind: %w[current_anchor reconciliation]).select(:id))
        .where(created_at: linked_at..)
        .where(user_modified: false)
        .where("entries.locked_attributes = '{}'::jsonb")
        .order(date: :desc, created_at: :desc)
    end
end
