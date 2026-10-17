require "test_helper"

class Assistant::Function::ReviewTransferTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::ReviewTransfer.new(@user)
    @outflow = create_transaction(account: accounts(:depository), amount: 64).transaction
    @inflow = create_transaction(account: accounts(:other_asset), amount: -64).transaction
    @transfer = Transfer.create!(outflow_transaction: @outflow, inflow_transaction: @inflow, status: "pending")
  end

  test "confirms a pending transfer" do
    result = @function.call("transfer_id" => @transfer.id, "action" => "confirm")

    assert_equal true, result[:success]
    assert_equal "confirmed", result[:action]
    assert @transfer.reload.confirmed?
  end

  test "rejects a pending transfer and remembers the pairing" do
    result = assert_difference({ "Transfer.count" => -1, "RejectedTransfer.count" => 1 }) do
      @function.call("transfer_id" => @transfer.id, "action" => "reject")
    end

    assert_equal "rejected", result[:action]
    assert_nil @outflow.reload.transfer
    assert RejectedTransfer.exists?(outflow_transaction_id: @outflow.id, inflow_transaction_id: @inflow.id)
  end

  test "refuses a confirmed transfer" do
    @transfer.confirm!

    result = @function.call("transfer_id" => @transfer.id, "action" => "reject")

    assert_equal "not_pending", result[:error]
    assert Transfer.exists?(@transfer.id)
  end

  test "a review that lost a race to another review changes nothing" do
    # Loaded while pending, then confirmed by a concurrent request
    stale = Transfer.find(@transfer.id)
    @transfer.confirm!
    @function.stubs(:find_transfer).returns(stale)

    result = @function.call("transfer_id" => @transfer.id, "action" => "reject")

    assert_equal "not_pending", result[:error]
    assert Transfer.find(@transfer.id).confirmed?
  end

  test "refuses an unknown action" do
    result = @function.call("transfer_id" => @transfer.id, "action" => "delete")

    assert_equal "invalid_arguments", result[:error]
  end

  test "requires write access to both accounts" do
    # family_member has full control of the checking account but no share of other_asset
    result = Assistant::Function::ReviewTransfer.new(users(:family_member)).call("transfer_id" => @transfer.id, "action" => "confirm")

    assert_equal "not_found", result[:error]
    assert @transfer.reload.pending?
  end

  test "does not resolve another family's transfer" do
    result = Assistant::Function::ReviewTransfer.new(users(:josh)).call("transfer_id" => @transfer.id, "action" => "confirm")

    assert_equal "not_found", result[:error]
  end
end
