require "test_helper"

class Loan::PaymentSplitterTest < ActiveSupport::TestCase
  include EntriesTestHelper

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

  test "splits a payment into a principal transfer and an interest expense" do
    payment = create_transaction(account: @checking, amount: 300, name: "Bridgecrest Payment")

    splitter = Loan::PaymentSplitter.new(payment_entry: payment, loan_account: @loan_account)
    assert splitter.applicable?

    transfer = nil
    assert_difference -> { @checking.entries.count } => 2, -> { @loan_account.entries.count } => 1 do
      transfer = splitter.split!
    end

    assert transfer.persisted?

    # Original payment becomes an excluded split parent with two children.
    payment.reload
    assert payment.excluded?
    assert_equal 2, payment.child_entries.count

    interest_child = payment.child_entries.find { |e| e.amount == 50 }
    principal_child = payment.child_entries.find { |e| e.amount == 250 }
    assert interest_child.present?
    assert principal_child.present?

    # Interest portion is a categorized expense, NOT part of the transfer.
    assert_equal @family.loan_interest_category, interest_child.transaction.category
    assert_not interest_child.transaction.transfer?

    # Principal portion is the outflow side of a loan-payment transfer.
    assert_equal "loan_payment", principal_child.transaction.kind
    assert_equal principal_child.transaction, transfer.outflow_transaction

    # Loan receives only the principal (negative reduces the liability balance).
    loan_entry = transfer.inflow_transaction.entry
    assert_equal @loan_account, loan_entry.account
    assert_equal(-250, loan_entry.amount)
    assert_equal "funds_movement", transfer.inflow_transaction.kind
  end

  test "reversing the transfer restores the original payment and removes the loan entry" do
    payment = create_transaction(account: @checking, amount: 300, name: "Bridgecrest Payment")
    transfer = Loan::PaymentSplitter.new(payment_entry: payment, loan_account: @loan_account).split!

    assert_difference -> { @loan_account.entries.count } => -1,
                      -> { Entry.where(parent_entry_id: payment.id).count } => -2 do
      transfer.destroy!
    end

    payment.reload
    assert_not payment.excluded?
    assert_equal 0, payment.child_entries.count
    assert_equal 300, payment.amount
  end

  test "is not applicable when auto-splitting is disabled" do
    @loan_account.loan.update!(auto_split_payments: false)
    payment = create_transaction(account: @checking, amount: 300)

    splitter = Loan::PaymentSplitter.new(payment_entry: payment, loan_account: @loan_account)

    assert_not splitter.applicable?
    assert_nil splitter.split!
  end

  test "is not applicable when the loan has no interest rate" do
    @loan_account.loan.update!(interest_rate: nil)
    payment = create_transaction(account: @checking, amount: 300)

    splitter = Loan::PaymentSplitter.new(payment_entry: payment, loan_account: @loan_account)

    assert_not splitter.applicable?
  end

  test "is not applicable for an entry already involved in a transfer or split" do
    payment = create_transaction(account: @checking, amount: 300)
    payment.update!(excluded: true)

    splitter = Loan::PaymentSplitter.new(payment_entry: payment, loan_account: @loan_account)

    assert_not splitter.applicable?
  end
end
