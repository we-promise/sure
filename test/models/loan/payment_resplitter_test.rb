require "test_helper"

class Loan::PaymentResplitterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @checking = accounts(:depository)
    @loan_account = Account.create! \
      family: @family,
      name: "Auto Loan",
      balance: 10000,
      currency: "USD",
      accountable: Loan.create!(subtype: "auto", interest_rate: 6, rate_type: "fixed", auto_split_payments: true)
  end

  test "retroactively splits existing full-amount payments in chronological order" do
    # Two legacy payments applied as full-amount transfers (pre-feature).
    create_full_payment(amount: 300, date: 2.months.ago.to_date)
    create_full_payment(amount: 300, date: 1.month.ago.to_date)

    Loan::PaymentResplitter.new(@loan_account).call

    # Each payment now records interest as an expense, principal against the loan.
    interest_entries = @checking.entries
                                .joins("JOIN transactions t ON t.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
                                .where(t: { category_id: @family.loan_interest_category.id })
                                .order(:date)

    # Month 1: 10000 * 6% / 12 = 50.00
    # Month 2: (10000 - 250) * 6% / 12 = 48.75  <- reflects the prior principal
    assert_equal [ 50.0, 48.75 ], interest_entries.map { |e| e.amount.to_f }

    # Loan now holds two principal entries (250.00 and 251.25), not the full 600.
    loan_principals = @loan_account.entries.order(:date).map { |e| e.amount.to_f }
    assert_equal [ -250.0, -251.25 ], loan_principals
  end

  test "is idempotent - already-split payments are not touched again" do
    create_full_payment(amount: 300, date: 1.month.ago.to_date)

    Loan::PaymentResplitter.new(@loan_account).call
    loan_entries_after_first = @loan_account.entries.order(:date).map { |e| e.amount.to_f }

    Loan::PaymentResplitter.new(@loan_account).call
    loan_entries_after_second = @loan_account.entries.order(:date).map { |e| e.amount.to_f }

    assert_equal loan_entries_after_first, loan_entries_after_second
  end

  private
    def create_full_payment(amount:, date:)
      Transfer::Creator.new(
        family: @family,
        source_account_id: @checking.id,
        destination_account_id: @loan_account.id,
        date: date,
        amount: amount
      ).create
    end
end
