# Brings the stored kinds of transfers into locked or long-term bank accounts
# in line with Transfer#kind_for_leg after a transfer from available money
# into such an account started counting as saving (investment_contribution).
# Kinds are stored per transaction, so transfers booked before that rule keep
# funds_movement until this runs; the same movement would otherwise be
# classified differently before and after the upgrade.
#
# Same guarantees as Transfer::InvestmentKindReconciler (only transfer kinds,
# no excluded entries or locked kinds, idempotent); only the destinations
# differ. Transfers into investment and crypto accounts, including those whose
# source is now a locked deposit, are that reconciler's job.
class Transfer::SavingsKindReconciler < Transfer::InvestmentKindReconciler
  private
    def transfers
      scope
        .joins(inflow_transaction: { entry: :account })
        .where(accounts: { accountable_type: "Depository", liquidity: Account::Liquidity::BOUND_LEVELS })
        .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
    end
end
