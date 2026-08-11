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

  test "leaves an interest-heavy payment as a full transfer instead of silently dropping it" do
    # Monthly interest on the opening balance is 10000 * 6% / 12 = 50.00, so a
    # $40 payment is entirely interest: principal would be <= 0 and the split is
    # not applicable. The original full-amount transfer must survive rather than
    # be destroyed with nothing to replace it, which would leave the payment
    # unlinked and drop the loan's principal reduction with no error.
    transfer = create_full_payment(amount: 40, date: 1.month.ago.to_date)
    loan_entry_id = transfer.inflow_transaction.entry.id

    Loan::PaymentResplitter.new(@loan_account).call

    assert Transfer.exists?(transfer.id), "original transfer was destroyed with no replacement"
    assert Entry.exists?(loan_entry_id), "loan principal reduction was dropped"

    # The loan still carries its single full-amount principal reduction...
    assert_equal [ -40.0 ], @loan_account.entries.map { |e| e.amount.to_f }

    # ...and no interest expense leaked onto the checking account.
    interest_entries = @checking.entries
                                .joins("JOIN transactions t ON t.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
                                .where(t: { category_id: @family.loan_interest_category.id })
    assert_empty interest_entries
  end

  test "retained multi-currency payment reduces the running balance by its loan-side amount" do
    # A EUR payment into a USD loan can't be split (currency mismatch), so it is
    # left as a full-amount transfer. The replay's running balance must fall by
    # the transfer's USD loan-side amount (100 EUR * 1.1 = 110 USD), not the raw
    # EUR cash figure, so a later same-currency payment prices interest correctly.
    eur_checking = Account.create! \
      family: @family, name: "EUR Checking", balance: 1000, currency: "EUR",
      accountable: Depository.new

    Transfer::Creator.new(
      family: @family,
      source_account_id: eur_checking.id,
      destination_account_id: @loan_account.id,
      date: 2.months.ago.to_date,
      amount: 100,
      exchange_rate: 1.1
    ).create

    create_full_payment(amount: 300, date: 1.month.ago.to_date)

    Loan::PaymentResplitter.new(@loan_account).call

    # Interest on the USD payment reflects 10000 - 110 = 9890 outstanding:
    # 9890 * 6% / 12 = 49.45 (it would be 49.50 if the EUR cash amount were used).
    interest = @checking.entries
                        .joins("JOIN transactions t ON t.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
                        .where(t: { category_id: @family.loan_interest_category.id })
                        .sole
    assert_equal 49.45, interest.amount.to_f
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
