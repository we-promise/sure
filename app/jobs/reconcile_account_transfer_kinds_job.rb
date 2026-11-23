# Re-derives the stored kinds of an account's transfers after its
# availability changed, since Transfer.kind_for_account depends on it. Runs in
# the background because an account can have a long transfer history.
class ReconcileAccountTransferKindsJob < ApplicationJob
  queue_as :medium_priority

  def perform(account)
    transaction_ids = Transaction.joins(:entry).where(entries: { account_id: account.id }).select(:id)
    scope = Transfer.where(inflow_transaction_id: transaction_ids).or(Transfer.where(outflow_transaction_id: transaction_ids))

    # Each reconciler only touches transfers into its own kind of account.
    Transfer::SavingsKindReconciler.new(scope: scope).run
    Transfer::InvestmentKindReconciler.new(scope: scope).run
  end
end
