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

  test "transfer with source fee adjusts validation" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 100)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -100)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
      source_fee_amount: 3
    )

    assert transfer.valid?
  end

  test "transfer with destination fee adjusts validation" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 100)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -100)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
      destination_fee_amount: 3
    )

    assert transfer.valid?
  end

  test "transfer with both source and destination fees adjusts validation" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 100)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -100)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
      source_fee_amount: 3,
      destination_fee_amount: 6
    )

    assert transfer.valid?
  end

  test "transfer with non-opposite entries fails validation" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 100)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -95)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
      source_fee_amount: 3
    )

    assert transfer.invalid?
    assert_equal "Must have opposite amounts", transfer.errors.full_messages.first
  end

  test "has_source_fee? returns true when source fee present" do
    transfer = transfers(:one)
    transfer.update_column(:source_fee_amount, 5)
    assert transfer.has_source_fee?
    assert transfer.has_fees?
  end

  test "has_destination_fee? returns true when destination fee present" do
    transfer = transfers(:one)
    transfer.update_column(:destination_fee_amount, 5)
    assert transfer.has_destination_fee?
    assert transfer.has_fees?
  end

  test "has_fees? returns false when no fees" do
    transfer = transfers(:one)
    refute transfer.has_fees?
  end

  test "total_fee sums source and destination fees" do
    transfer = transfers(:one)
    transfer.update_columns(source_fee_amount: 3, destination_fee_amount: 2)
    assert_equal 5, transfer.total_fee
  end

  test "destination fee larger than amount inverts inflow sign and fails validation" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 100)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: 50)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
      destination_fee_amount: 150
    )

    # inflow amount (50) is positive, which means destination is also outflowing
    assert transfer.invalid?
    assert_equal "Must have opposite amounts", transfer.errors.full_messages.first
  end

  test "negative source fee is rejected" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
      source_fee_amount: -5
    )

    assert transfer.invalid?
    assert_includes transfer.errors.full_messages, "Source fee amount must be greater than or equal to 0"
  end

  test "negative destination fee is rejected" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)

    transfer = Transfer.new(
      inflow_transaction: inflow_entry.transaction,
      outflow_transaction: outflow_entry.transaction,
      destination_fee_amount: -5
    )

    assert transfer.invalid?
    assert_includes transfer.errors.full_messages, "Destination fee amount must be greater than or equal to 0"
  end
end
