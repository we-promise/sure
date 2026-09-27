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

  test "destroy! clears the idempotency key so a retried request can create a new transfer" do
    idempotency_key = SecureRandom.uuid

    transfer = Transfer::Creator.new(
      family: families(:dylan_family),
      source_account_id: accounts(:depository).id,
      destination_account_id: accounts(:credit_card).id,
      date: Date.current,
      amount: 100,
      idempotency_key: idempotency_key
    ).create

    transfer.destroy!

    assert_nil transfer.outflow_transaction.entry.reload.idempotency_key
    assert_nil transfer.inflow_transaction.entry.reload.idempotency_key

    # A retry of the original create request (e.g. the user resubmits after
    # rejecting/undoing the first transfer) must not find a stale entry with
    # this key and raise RecordNotUnique - it should create a fresh transfer.
    assert_difference "Transfer.count", 1 do
      Transfer::Creator.new(
        family: families(:dylan_family),
        source_account_id: accounts(:depository).id,
        destination_account_id: accounts(:credit_card).id,
        date: Date.current,
        amount: 100,
        idempotency_key: idempotency_key
      ).create
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

  test "confirm! marks both legs with the destination account's transfer kinds" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))

    transfer.confirm!

    assert transfer.reload.confirmed?
    assert_equal "cc_payment", transfer.outflow_transaction.reload.kind
    assert_equal "funds_movement", transfer.inflow_transaction.reload.kind
  end

  test "confirm! assigns the investment contributions category to an uncategorized outflow" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:investment))

    transfer.confirm!

    outflow = transfer.outflow_transaction.reload
    assert_equal "investment_contribution", outflow.kind
    assert_equal families(:dylan_family).investment_contributions_category, outflow.category
  end

  test "confirm! keeps an outflow category the user already set" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:investment))
    transfer.outflow_transaction.update!(category: categories(:income))

    transfer.confirm!

    assert_equal categories(:income), transfer.outflow_transaction.reload.category
  end

  test "reject! leaves the kind of a pending transfer's transactions alone" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))
    transfer.outflow_transaction.update!(kind: "one_time")

    transfer.reject!

    assert_equal "one_time", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "reject! keeps a transfer kind that predates a pending match" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))
    transfer.outflow_transaction.update!(kind: "funds_movement")

    transfer.reject!

    assert_equal "funds_movement", transfer.outflow_transaction.reload.kind
  end

  test "reject! resets the transfer kinds of a confirmed transfer" do
    transfer = create_pending_transfer(from: accounts(:depository), to: accounts(:credit_card))
    transfer.confirm!

    transfer.reject!

    assert_equal "standard", transfer.outflow_transaction.reload.kind
    assert_equal "standard", transfer.inflow_transaction.reload.kind
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

  private
    def create_pending_transfer(from:, to:)
      outflow_entry = create_transaction(date: Date.current, account: from, amount: 500)
      inflow_entry = create_transaction(date: Date.current, account: to, amount: -500)

      Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction)
    end
end
