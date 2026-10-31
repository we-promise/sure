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

  test "returns not found for an invalid id" do
    result = @function.call("id" => "not-a-uuid")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "account guard rejects mismatches and malformed IDs without deleting" do
    [ accounts(:credit_card).id, "not-a-uuid", "" ].each do |account_id|
      assert_no_difference [ "Entry.count", "Transaction.count" ] do
        result = @function.call("id" => @transaction.id, "account_id" => account_id)
        assert_equal "not_found", result[:error]
      end
    end
    assert Transaction.exists?(@transaction.id)
  end

  test "matching account guard preserves the public deletion response" do
    entry_id = @transaction.entry.id
    result = @function.call("id" => @transaction.id, "account_id" => @transaction.entry.account_id)

    assert result[:success]
    assert result[:deleted]
    assert_equal @transaction.id, result.dig(:transaction, :id)
    assert_equal entry_id, result.dig(:transaction, :entry_id)
    assert_not Entry.exists?(entry_id)
  end

  test "a changed account is rechecked after locking the entry" do
    original_lock = Account::MutationAccess.method(:lock!)
    destination = accounts(:credit_card)
    racing_lock = lambda do |**arguments|
      locked = original_lock.call(**arguments)
      @transaction.entry.update_column(:account_id, destination.id)
      locked
    end

    Account::MutationAccess.stub(:lock!, racing_lock) do
      result = @function.call("id" => @transaction.id)
      assert_equal "not_found", result[:error]
    end
    assert Transaction.exists?(@transaction.id)
    assert_equal destination.id, @transaction.entry.reload.account_id
  end

  test "post-delete queue failures report the committed deletion" do
    Entry.any_instance.stubs(:sync_account_later).raises(StandardError, "job backend unavailable")
    id = @transaction.id
    result = @function.call("id" => id)

    assert result[:success]
    assert result[:deleted]
    assert_match(/could not be enqueued/, result[:warning])
    assert_not Transaction.exists?(id)
  end
end
