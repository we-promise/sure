# Retroactively re-splits loan payments that were linked to the loan BEFORE
# automatic splitting was enabled (i.e. applied as a full-amount transfer that
# reduced the whole balance).
#
# Payments are replayed in chronological order because each period's interest
# depends on the outstanding balance left by the prior payment. The running
# balance is tracked analytically from the loan's original balance rather than
# from materialized balances, so the result is deterministic and independent of
# sync timing. Already-split payments are skipped, so this is idempotent.
class Loan::PaymentResplitter
  def initialize(loan_account)
    @loan_account = loan_account
  end

  def call
    return unless loan.splits_payments?

    outstanding = loan.original_balance.amount

    resplittable_transfers.each do |transfer|
      cash_entry = transfer.outflow_transaction.entry
      loan_entry = transfer.inflow_transaction.entry
      payment_amount = cash_entry.amount
      as_of_date = cash_entry.date

      Transfer.transaction do
        # Full (non-split) transfer: destroying it just unlinks and resets kinds.
        transfer.destroy!
        # Remove the full-amount principal reduction on the loan.
        loan_entry.destroy!

        Loan::PaymentSplitter.new(
          payment_entry: cash_entry.reload,
          loan_account: @loan_account,
          outstanding_balance: outstanding
        ).split!
      end

      interest = loan.interest_portion(
        payment_amount: payment_amount, as_of_date: as_of_date, outstanding_balance: outstanding
      )
      outstanding -= (payment_amount.to_d.abs - interest.amount)
    end

    @loan_account.sync_later
  end

  private
    def loan
      @loan ||= @loan_account.accountable
    end

    # Loan-payment transfers into this loan whose cash side is a plain, full
    # payment (not already split).
    def resplittable_transfers
      loan_transaction_ids = @loan_account.entries.where(entryable_type: "Transaction").pluck(:entryable_id)

      Transfer
        .where(inflow_transaction_id: loan_transaction_ids)
        .includes(inflow_transaction: :entry, outflow_transaction: :entry)
        .select { |t| t.outflow_transaction&.entry.present? }
        .reject { |t| t.outflow_transaction.entry.split_child? }
        .sort_by { |t| t.outflow_transaction.entry.date }
    end
end
