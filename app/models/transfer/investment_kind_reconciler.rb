# Brings the stored kinds of transfers into investment/crypto accounts in line
# with Transfer#kind_for_leg. Older syncs and match paths left some of these
# legs on a kind the current rules no longer give them, e.g. an
# investment-to-investment outflow still marked investment_contribution
# (counted as a budgeted expense), or a matched brokerage inflow a provider
# sync turned back into investment_contribution. Provider syncs only repair
# the rows they happen to replay, so history outside the replay window keeps
# the old kinds until this runs.
#
# Bounded and idempotent:
# - only transfers whose destination is an investment or crypto account;
# - only legs whose current kind is one of Transaction::TRANSFER_KINDS, so a
#   kind the user chose (standard, one_time) is never overwritten;
# - excluded entries and transactions with a locked kind are left alone;
# - a second run finds nothing to change.
#
# Entries created or matched through Transfer::Creator and the match dialog
# are user_modified by design, so that flag does not mark a user's choice of
# kind here and is not a reason to skip a leg.
class Transfer::InvestmentKindReconciler
  INVESTMENT_TYPES = %w[Investment Crypto].freeze

  Result = Data.define(:checked, :changed)

  def initialize(scope: Transfer.all, dry_run: false)
    @scope = scope
    @dry_run = dry_run
  end

  def run
    checked = 0
    changed = Hash.new(0)

    transfers.find_each do |transfer|
      checked += 1

      [ transfer.inflow_transaction, transfer.outflow_transaction ].each do |transaction|
        next unless repairable?(transaction)

        expected = transfer.kind_for_leg(transaction)
        next if transaction.kind == expected

        changed["#{transaction.kind}->#{expected}"] += 1
        repair!(transaction, expected) unless dry_run
      end
    end

    Result.new(checked: checked, changed: changed)
  end

  private
    attr_reader :scope, :dry_run

    def transfers
      scope
        .joins(inflow_transaction: { entry: :account })
        .where(accounts: { accountable_type: INVESTMENT_TYPES })
        .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
    end

    def repairable?(transaction)
      Transaction::TRANSFER_KINDS.include?(transaction.kind) &&
        !transaction.entry.excluded? &&
        !transaction.locked?(:kind)
    end

    def repair!(transaction, kind)
      now = Time.current
      Transaction.transaction do
        transaction.update_columns(kind: kind, updated_at: now)
        # Report and transaction-list caches are keyed on entries' updated_at.
        transaction.entry.update_columns(updated_at: now)
      end
    end
end
