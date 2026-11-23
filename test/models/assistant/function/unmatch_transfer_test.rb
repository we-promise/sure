require "test_helper"

class Assistant::Function::UnmatchTransferTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include PreviewTokenTestHelper

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

    result = unmatch("transaction_id" => inflow.id)

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
    result = unmatch("transfer_id" => @transfer.id, "reject" => false)

    assert result[:success]
    assert_equal false, result[:rejected]
    assert_nil Transfer.find_by(id: @transfer.id)
    assert_not RejectedTransfer.exists?(inflow_transaction_id: @transfer.inflow_transaction_id)
  end

  test "a null reject rejects the pairing, like an omitted one" do
    result = unmatch("transfer_id" => @transfer.id, "reject" => nil)

    assert result[:success]
    assert_equal true, result[:rejected]
    assert RejectedTransfer.exists?(inflow_transaction_id: @transfer.inflow_transaction_id)
  end

  test "unmatches a pending auto-match" do
    @transfer.update!(status: "pending")

    result = unmatch("transaction_id" => @transfer.outflow_transaction_id)

    assert result[:success]
    assert_equal "pending", result[:transfer][:status]
    assert_nil Transfer.find_by(id: @transfer.id)

    # A pending match never changed the kinds, so a kind set before it stays.
    assert_equal "cc_payment", @transfer.outflow_transaction.reload.kind
    assert_equal "cc_payment", result[:transfer][:outflow][:kind_after]
    assert_includes result[:message], "Outflow kind is now cc_payment"
  end

  test "without a preview_token it previews the unlink, fee deletions included, and changes nothing" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    fee = create_transaction(account: accounts(:depository), name: "Transfer fee", amount: 2).entryable
    transfer.fee_transactions << fee

    assert_no_difference [ "Transfer.count", "RejectedTransfer.count", "Transaction.count" ] do
      result = @function.call("transfer_id" => transfer.id)

      assert result[:success]
      assert_equal false, result[:unmatched]
      assert_equal transfer.id, result[:preview][:transfer][:id]
      assert_equal true, result[:preview][:reject]
      assert_equal [ fee.id ], result[:preview][:transfer][:deleted_fee_transactions].map { |t| t[:id] }
      assert result[:preview_token].present?
    end
  end

  test "a dry_run call only previews" do
    assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
      result = @function.call("transfer_id" => @transfer.id, "dry_run" => true)

      assert_equal false, result[:unmatched]
      assert result[:preview_token].present?
    end
    assert_equal "cc_payment", @transfer.outflow_transaction.reload.kind
  end

  test "refuses a forged token, another transfer's token, another user's token, another tool's token and an expired one" do
    other = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 75)
    other_token = @function.call("transfer_id" => other.id)[:preview_token]
    foreign_token = Assistant::Function::UnmatchTransfer.new(users(:family_member)).tap { |f| f.stubs(:find_transfer).returns(@transfer) }
      .call("transfer_id" => @transfer.id)[:preview_token]
    delete_token = Assistant::Function::DeleteTransaction.new(@user).call("id" => @transfer.inflow_transaction_id)[:preview_token]
    assert [ other_token, foreign_token, delete_token ].all?(&:present?)

    [ "forged", other_token, foreign_token, delete_token ].each do |token|
      assert_equal "preview_required", @function.call("transfer_id" => @transfer.id, "preview_token" => token)[:error]
    end

    token = @function.call("transfer_id" => @transfer.id)[:preview_token]
    travel Assistant::Function::PreviewToken::PREVIEW_TOKEN_TTL + 1.minute do
      assert_equal "preview_required", @function.call("transfer_id" => @transfer.id, "preview_token" => token)[:error]
    end
    assert Transfer.exists?(@transfer.id)
  end

  test "refuses a token previewed with another reject choice or before a fee was attached" do
    token = @function.call("transfer_id" => @transfer.id, "reject" => false)[:preview_token]
    result = @function.call("transfer_id" => @transfer.id, "preview_token" => token)
    assert_equal "preview_stale", result[:error]
    assert_equal true, result[:preview][:reject]

    token = @function.call("transfer_id" => @transfer.id)[:preview_token]
    @transfer.fee_transactions << create_transaction(account: accounts(:depository), name: "Late fee", amount: 3).entryable
    result = @function.call("transfer_id" => @transfer.id, "preview_token" => token)
    assert_equal "preview_stale", result[:error]
    assert_equal 1, result[:preview][:transfer][:deleted_fee_transactions].size

    assert Transfer.exists?(@transfer.id)
  end

  test "refuses a token when a fee is attached after the token was checked" do
    token = @function.call("transfer_id" => @transfer.id)[:preview_token]
    change_after_token_check(@function) do
      @transfer.fee_transactions << create_transaction(account: accounts(:depository), name: "Late fee", amount: 3).entryable
    end

    result = @function.call("transfer_id" => @transfer.id, "preview_token" => token)

    assert_equal "preview_stale", result[:error]
    assert_equal 1, result[:preview][:transfer][:deleted_fee_transactions].size
    assert Transfer.exists?(@transfer.id)
  end

  test "lists and deletes fee transactions, like the UI" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    fee = create_transaction(account: accounts(:depository), name: "Transfer fee", amount: 2).entryable
    fee_entry_id = fee.entry.id
    transfer.fee_transactions << fee

    result = unmatch("transfer_id" => transfer.id, "reject" => false)

    assert result[:success]
    assert_equal [ fee.id ], result[:transfer][:deleted_fee_transactions].map { |t| t[:id] }
    assert_nil Transaction.find_by(id: fee.id)
    assert_nil Entry.find_by(id: fee_entry_id)
  end

  test "reports success with a warning when the fee resync can't be enqueued" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    transfer.fee_transactions << create_transaction(account: accounts(:depository), name: "Transfer fee", amount: 2).entryable
    Account.any_instance.stubs(:sync_later).raises(StandardError, "queue down")

    result = unmatch("transfer_id" => transfer.id)

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

    result = unmatch({ "transfer_id" => @transfer.id }, function)

    assert_equal "not_found", result[:error]
    assert Transfer.exists?(@transfer.id)
  end

  test "returns not_found for another family's user" do
    result = Assistant::Function::UnmatchTransfer.new(users(:empty)).call("transfer_id" => @transfer.id)

    assert_equal "not_found", result[:error]
    assert Transfer.exists?(@transfer.id)
  end

  private
    def unmatch(params, function = @function)
      token = function.call(params)[:preview_token]
      assert token.present?, "the preview issued no token"
      function.call(params.merge("preview_token" => token))
    end
end
