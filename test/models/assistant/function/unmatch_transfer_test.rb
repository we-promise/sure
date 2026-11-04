require "test_helper"

class Assistant::Function::UnmatchTransferTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::UnmatchTransfer.new(@user)
    @transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:credit_card), amount: 250)
    @transfer.outflow_transaction.update!(kind: "cc_payment")
  end

  test "is registered for the assistant and MCP" do
    assert_includes Assistant.function_classes(@user), Assistant::Function::UnmatchTransfer
  end

  test "unmatches a confirmed transfer by either transaction and rejects the pairing" do
    outflow = @transfer.outflow_transaction
    inflow = @transfer.inflow_transaction

    result = @function.call("transaction_id" => inflow.id)

    assert result[:success]
    assert result[:unmatched]
    assert result[:rejected]
    assert_equal "confirmed", result[:transfer][:status]
    assert_equal outflow.id, result[:transfer][:outflow][:id]
    assert_equal "cc_payment", result[:transfer][:outflow][:kind]

    assert_nil Transfer.find_by(id: @transfer.id)
    assert_equal "standard", outflow.reload.kind
    assert_equal "standard", inflow.reload.kind
    assert_equal "standard", result[:transfer][:outflow][:kind_after]
    assert_equal "standard", result[:transfer][:inflow][:kind_after]
    assert RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)
  end

  test "reject false only unlinks" do
    result = @function.call("transfer_id" => @transfer.id, "reject" => false)

    assert result[:success]
    assert_equal false, result[:rejected]
    assert_nil Transfer.find_by(id: @transfer.id)
    assert_not RejectedTransfer.exists?(inflow_transaction_id: @transfer.inflow_transaction_id)
  end

  test "a null reject rejects the pairing, like an omitted one" do
    result = @function.call("transfer_id" => @transfer.id, "reject" => nil)

    assert result[:success]
    assert_equal true, result[:rejected]
    assert RejectedTransfer.exists?(inflow_transaction_id: @transfer.inflow_transaction_id)
  end

  test "unmatches a pending auto-match" do
    @transfer.update!(status: "pending")

    result = @function.call("transaction_id" => @transfer.outflow_transaction_id)

    assert result[:success]
    assert_equal "pending", result[:transfer][:status]
    assert_nil Transfer.find_by(id: @transfer.id)

    # A pending match never changed the kinds, so a kind set before it stays.
    assert_equal "cc_payment", @transfer.outflow_transaction.reload.kind
    assert_equal "cc_payment", result[:transfer][:outflow][:kind_after]
    assert_includes result[:message], "Outflow kind is now cc_payment"
  end

  test "dry run changes nothing" do
    assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
      result = @function.call("transfer_id" => @transfer.id, "dry_run" => true)

      assert result[:success]
      assert result[:dry_run]
      assert_equal @transfer.id, result[:transfer][:id]
    end

    assert_equal "cc_payment", @transfer.outflow_transaction.reload.kind
  end

  test "lists and deletes fee transactions, like the UI" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    fee = create_transaction(account: accounts(:depository), name: "Transfer fee", amount: 2).entryable
    fee_entry_id = fee.entry.id
    transfer.fee_transactions << fee

    result = @function.call("transfer_id" => transfer.id, "reject" => false)

    assert result[:success]
    assert_equal [ fee.id ], result[:transfer][:deleted_fee_transactions].map { |t| t[:id] }
    assert_nil Transaction.find_by(id: fee.id)
    assert_nil Entry.find_by(id: fee_entry_id)
  end

  test "reports success with a warning when the fee resync can't be enqueued" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    transfer.fee_transactions << create_transaction(account: accounts(:depository), name: "Transfer fee", amount: 2).entryable
    Account.any_instance.stubs(:sync_later).raises(StandardError, "queue down")

    result = @function.call("transfer_id" => transfer.id)

    assert result[:success]
    assert_match "could not be enqueued", result[:warning]
    assert_nil Transfer.find_by(id: transfer.id)
  end

  test "requires exactly one of transaction_id or transfer_id" do
    assert_equal "invalid_arguments", @function.call({})[:error]
    assert_equal "invalid_arguments", @function.call("transfer_id" => @transfer.id, "transaction_id" => @transfer.inflow_transaction_id)[:error]
  end

  test "returns not_found for a transaction that is not in a transfer" do
    result = @function.call("transaction_id" => transactions(:one).id)

    assert_equal "not_found", result[:error]
  end

  test "returns not_found unless both accounts are writable" do
    # family_member has a read-only share of the credit card
    result = Assistant::Function::UnmatchTransfer.new(users(:family_member)).call("transfer_id" => @transfer.id)

    assert_equal "not_found", result[:error]
    assert Transfer.exists?(@transfer.id)
  end

  test "rechecks write access under the lock" do
    # As if the lookup had passed before the read-only share took effect.
    function = Assistant::Function::UnmatchTransfer.new(users(:family_member))
    function.stubs(:find_transfer).returns(@transfer)

    result = function.call("transfer_id" => @transfer.id)

    assert_equal "not_found", result[:error]
    assert Transfer.exists?(@transfer.id)
  end

  test "returns not_found for another family's user" do
    result = Assistant::Function::UnmatchTransfer.new(users(:empty)).call("transfer_id" => @transfer.id)

    assert_equal "not_found", result[:error]
    assert Transfer.exists?(@transfer.id)
  end
end
