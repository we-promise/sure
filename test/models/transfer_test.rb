require "test_helper"

class TransferTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @outflow = transactions(:transfer_out)
    @inflow = transactions(:transfer_in)
  end

  test "transfer destroyed if either transaction is destroyed" do
    assert_difference [ "Transfer.count", "Transaction.count", "Entry.count" ], -1 do
      @outflow.entry.destroy
    end
  end

  test "transfer has different accounts, opposing amounts, and within 4 days of each other" do
    outflow_entry = create_transaction(date: 1.day.ago.to_date, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    assert_difference -> { Transfer.count } => 1 do
      Transfer.create!(
        inflow_transaction: inflow_entry.transaction,
        outflow_transaction: outflow_entry.transaction,
      )
    end
  end

  test "transfer cannot have 2 transactions from the same account" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: 1.day.ago.to_date, account: accounts(:depository), amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
    )

    assert_no_difference -> { Transfer.count } do
      transfer.save
    end

    assert_equal "Must be from different accounts", transfer.errors.full_messages.first
  end

  test "Transfer transactions must have opposite amounts" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -400)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
    )

    assert_no_difference -> { Transfer.count } do
      transfer.save
    end

    assert_equal "Must have opposite amounts", transfer.errors.full_messages.first
  end

  test "transfer dates must be within 4 days of each other" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: 5.days.ago.to_date, account: accounts(:credit_card), amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
    )

    assert_no_difference -> { Transfer.count } do
      transfer.save
    end

    assert_equal "Must be within 4 days", transfer.errors.full_messages.first
  end

  test "transfer must be from the same family" do
    family1 = families(:empty)
    family2 = families(:dylan_family)

    family1_account = family1.accounts.create!(name: "Family 1 Account", balance: 5000, currency: "USD", accountable: Depository.new)
    family2_account = family2.accounts.create!(name: "Family 2 Account", balance: 5000, currency: "USD", accountable: Depository.new)

    outflow_txn = create_transaction(date: Date.current, account: family1_account, amount: 500)
    inflow_txn = create_transaction(date: Date.current, account: family2_account, amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_txn.transaction,
      outflow_transaction: outflow_txn.transaction,
    )

    assert transfer.invalid?
    assert_equal "Must be from same family", transfer.errors.full_messages.first
  end

  test "transaction can only belong to one transfer" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry1 = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    inflow_entry2 = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    Transfer.create!(inflow_transaction: inflow_entry1.transaction, outflow_transaction: outflow_entry.transaction)

    assert_raises ActiveRecord::RecordInvalid do
      Transfer.create!(inflow_transaction: inflow_entry2.transaction, outflow_transaction: outflow_entry.transaction)
    end
  end

  test "kind_for_account returns investment_contribution for investment accounts" do
    assert_equal "investment_contribution", Transfer.kind_for_account(accounts(:investment))
  end

  test "kind_for_account returns investment_contribution for crypto accounts" do
    assert_equal "investment_contribution", Transfer.kind_for_account(accounts(:crypto))
  end

  test "kind_for_account returns loan_payment for loan accounts" do
    assert_equal "loan_payment", Transfer.kind_for_account(accounts(:loan))
  end

  test "kind_for_account returns cc_payment for credit card accounts" do
    assert_equal "cc_payment", Transfer.kind_for_account(accounts(:credit_card))
  end

  test "kind_for_account returns funds_movement for depository accounts" do
    assert_equal "funds_movement", Transfer.kind_for_account(accounts(:depository))
  end

  test "has_source_fee? returns true when source fee present" do
    transfer = transfers(:one)
    entry = accounts(:depository).entries.create!(name: "Fee", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new(kind: "standard"))
    transfer.fee_transactions << entry.entryable
    assert transfer.has_source_fee?
    assert transfer.has_fees?
  end

  test "has_destination_fee? returns true when destination fee present" do
    transfer = transfers(:one)
    entry = accounts(:credit_card).entries.create!(name: "Fee", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new(kind: "standard"))
    transfer.fee_transactions << entry.entryable
    assert transfer.has_destination_fee?
    assert transfer.has_fees?
  end

  test "has_fees? returns false when no fees" do
    transfer = transfers(:one)
    refute transfer.has_fees?
  end

  test "total_fee sums source and destination fees" do
    transfer = transfers(:one)
    entry1 = accounts(:depository).entries.create!(name: "Fee", date: Date.current, amount: 3, currency: "USD", entryable: Transaction.new(kind: "standard"))
    entry2 = accounts(:credit_card).entries.create!(name: "Fee", date: Date.current, amount: 2, currency: "USD", entryable: Transaction.new(kind: "standard"))
    transfer.fee_transactions << entry1.entryable << entry2.entryable
    assert_equal 5, transfer.total_fee
  end

  test "confirm! applies transfer kind and investment category to a pending transfer" do
    investment = accounts(:investment)
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "standard")
    inflow_entry = create_transaction(date: Date.current, account: investment, amount: -500, kind: "standard")

    transfer = Transfer.create!(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction
    )

    assert transfer.pending?
    assert_equal "standard", outflow_entry.transaction.reload.kind
    assert_nil outflow_entry.transaction.category

    transfer.confirm!

    assert transfer.confirmed?
    assert_equal "investment_contribution", outflow_entry.transaction.reload.kind
    assert_equal "funds_movement", inflow_entry.transaction.reload.kind
    assert_equal accounts(:depository).family.investment_contributions_category, outflow_entry.transaction.reload.category
  end

  test "confirm! does not overwrite an already-set category" do
    investment = accounts(:investment)
    category = categories(:food_and_drink)
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "standard")
    inflow_entry = create_transaction(date: Date.current, account: investment, amount: -500, kind: "standard")
    outflow_entry.transaction.update!(category: category)

    transfer = Transfer.create!(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction
    )

    transfer.confirm!

    assert_equal category, outflow_entry.transaction.reload.category
  end

  test "confirm! on an already-confirmed transfer does not re-apply kind" do
    transfer = transfers(:one)
    transfer.confirm!
    outflow_kind = transfer.outflow_transaction.reload.kind

    transfer.outflow_transaction.update!(kind: "standard")
    transfer.confirm!

    assert_equal "standard", transfer.outflow_transaction.reload.kind
  end

  test "confirm! raises and does not apply kind when the transfer was concurrently rejected" do
    investment = accounts(:investment)
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "standard")
    inflow_entry = create_transaction(date: Date.current, account: investment, amount: -500, kind: "standard")

    transfer = Transfer.create!(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction
    )

    # Simulate a reject that completes on another connection between the
    # confirm request loading its in-memory @transfer and calling confirm!.
    Transfer.find(transfer.id).reject!

    assert_raises(ActiveRecord::RecordNotFound) { transfer.confirm! }

    assert_equal "standard", outflow_entry.transaction.reload.kind
    assert_equal "standard", inflow_entry.transaction.reload.kind
    assert_nil outflow_entry.transaction.reload.category
  end

  test "reject! raises and does not revert kind when the transfer was concurrently confirmed" do
    investment = accounts(:investment)
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "standard")
    inflow_entry = create_transaction(date: Date.current, account: investment, amount: -500, kind: "standard")

    transfer = Transfer.create!(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction
    )

    # Simulate a confirm that completes on another connection between the
    # reject request loading its in-memory @transfer and calling reject!.
    Transfer.find(transfer.id).confirm!

    assert_raises(ActiveRecord::RecordNotFound) { transfer.reject! }

    assert transfer.reload.confirmed?
    assert_equal "investment_contribution", outflow_entry.transaction.reload.kind
    assert_equal "funds_movement", inflow_entry.transaction.reload.kind
    assert_equal accounts(:depository).family.investment_contributions_category, outflow_entry.transaction.reload.category
  end
end
