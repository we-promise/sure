require "test_helper"

class Assistant::Function::DeleteTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::DeleteTransaction.new(@user)
  end

  test "deletes a standard transaction from a writable account" do
    transaction_id = @transaction.id
    entry_id = @transaction.entry.id

    result = @function.call("id" => transaction_id)

    assert_equal true, result[:success]
    assert_equal transaction_id, result[:deleted_transaction_id]
    assert_not Transaction.exists?(transaction_id)
    assert_not Entry.exists?(entry_id)
  end

  test "does not let read-only collaborators delete transactions" do
    transaction = transactions(:transfer_in)
    function = Assistant::Function::DeleteTransaction.new(users(:family_member))

    result = function.call("id" => transaction.id)

    assert_equal false, result[:success]
    assert_equal "not_authorized", result[:error]
    assert Transaction.exists?(transaction.id)
  end

  test "requires transfer actions for linked transfer transactions" do
    result = @function.call("id" => transactions(:transfer_out).id)

    assert_equal false, result[:success]
    assert_equal "transfer_transaction", result[:error]
  end
end
