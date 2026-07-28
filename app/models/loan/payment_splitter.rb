# Splits a single loan payment (an existing entry on a cash account that is
# being linked to a loan) into two parts:
#
#   1. the principal portion, linked to the loan as a transfer so it reduces
#      the loan's balance, and
#   2. the interest portion, recorded as a categorized expense on the cash
#      account (it does not reduce the loan balance).
#
# This mirrors what a user would otherwise do by hand each month via a manual
# split transaction. The interest/principal breakdown is derived from the
# loan's outstanding balance and rate at the time of the payment, so it changes
# every period as the loan amortizes.
class Loan::PaymentSplitter
  def initialize(payment_entry:, loan_account:, outstanding_balance: nil)
    @payment_entry = payment_entry
    @loan_account = loan_account
    @outstanding_balance = outstanding_balance
  end

  # Whether this payment should be split. Requires the loan to have automatic
  # splitting enabled with a usable rate, a same-currency cash payment, a plain
  # (non-transfer, non-split) source entry, and a positive interest AND
  # principal portion (a payment smaller than the accrued interest, or against a
  # paid-off loan, falls back to the normal full-amount transfer).
  def applicable?
    @loan_account.loan? &&
      loan&.splits_payments? &&
      same_currency? &&
      splittable_source? &&
      @payment_entry.amount.to_d.positive? &&
      interest.amount.positive? &&
      principal.amount.positive?
  end

  # Performs the split and links the principal portion to the loan. Returns the
  # created Transfer, or nil when the payment is not applicable for splitting
  # (callers should fall back to a normal full-amount transfer).
  def split!
    return nil unless applicable?

    Transfer.transaction do
      principal_child, _interest_child = @payment_entry.split!([
        { name: principal_name, amount: principal.amount, category_id: nil },
        { name: interest_name, amount: interest.amount, category_id: interest_category.id }
      ])

      loan_transaction = Transaction.new(
        kind: "funds_movement",
        entry: @loan_account.entries.build(
          amount: principal.amount * -1,
          currency: @loan_account.currency,
          date: @payment_entry.date,
          name: "Payment from #{@payment_entry.account.name}",
          user_modified: true
        )
      )

      transfer = Transfer.create!(
        inflow_transaction: loan_transaction,
        outflow_transaction: principal_child.transaction,
        status: "confirmed"
      )

      principal_child.transaction.update!(kind: Transfer.kind_for_account(@loan_account))

      transfer
    end
  end

  private
    def loan
      @loan ||= @loan_account.accountable
    end

    def interest
      @interest ||= loan.interest_portion(
        payment_amount: @payment_entry.amount, as_of_date: @payment_entry.date, outstanding_balance: @outstanding_balance
      )
    end

    def principal
      @principal ||= loan.principal_portion(
        payment_amount: @payment_entry.amount, as_of_date: @payment_entry.date, outstanding_balance: @outstanding_balance
      )
    end

    def interest_category
      @interest_category ||= @loan_account.family.loan_interest_category
    end

    def same_currency?
      @payment_entry.currency == @loan_account.currency
    end

    def splittable_source?
      txn = @payment_entry.transaction
      txn.present? &&
        !txn.transfer? &&
        !@payment_entry.split_parent? &&
        !@payment_entry.split_child? &&
        !@payment_entry.excluded?
    end

    def principal_name
      "Principal — Payment to #{@loan_account.name}"
    end

    def interest_name
      "Interest — Payment to #{@loan_account.name}"
    end
end
