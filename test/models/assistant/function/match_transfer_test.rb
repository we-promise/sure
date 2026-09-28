require "test_helper"

class Assistant::Function::MatchTransferTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::MatchTransfer.new(@user)
    @checking = accounts(:depository)
    @card = accounts(:credit_card)
    @loan = accounts(:loan)
  end

  test "matches with an existing counterpart" do
    outflow = create_transaction(account: @checking, amount: 120).transaction
    inflow = create_transaction(account: @card, amount: -120).transaction

    result = @function.call("transaction_id" => outflow.id, "counterpart_transaction_id" => inflow.id)

    assert_equal true, result[:success]
    assert_equal false, result[:created_counterpart]
    assert_equal "confirmed", result[:transfer][:status]
    assert_equal outflow.id, result[:transfer][:outflow][:transaction_id]
    assert_equal inflow.id, result[:transfer][:inflow][:transaction_id]
    assert_equal "cc_payment", result[:transfer][:outflow][:kind]
  end

  test "creates the counterpart in a target account" do
    outflow = create_transaction(account: @checking, amount: 289.60).transaction

    result = assert_difference "Entry.count", 1 do
      @function.call("transaction_id" => outflow.id, "target_account_id" => @loan.id)
    end

    assert_equal true, result[:success]
    assert_equal true, result[:created_counterpart]
    assert_equal @loan.id, result[:transfer][:inflow][:account_id]
    assert_equal "loan_payment", result[:transfer][:outflow][:kind]
  end

  test "dry run describes the match without changing anything" do
    outflow = create_transaction(account: @checking, amount: 289.60).transaction

    result = assert_no_difference [ "Entry.count", "Transfer.count" ] do
      @function.call("transaction_id" => outflow.id, "target_account_id" => @loan.id, "dry_run" => true)
    end

    assert_equal true, result[:success]
    assert_equal true, result[:dry_run]
    assert_equal @loan.id, result[:creates_counterpart_in][:account_id]
    assert_equal "loan_payment", result[:outflow_kind]
    assert_equal "standard", outflow.reload.kind
  end

  test "dry run reports validation errors" do
    outflow = create_transaction(account: @checking, amount: 100).transaction
    wrong = create_transaction(account: @card, amount: -99).transaction

    result = @function.call("transaction_id" => outflow.id, "counterpart_transaction_id" => wrong.id, "dry_run" => true)

    assert_equal false, result[:success]
    assert_equal "not_a_candidate", result[:error]
  end

  test "matching the same pair again is a no-op" do
    outflow = create_transaction(account: @checking, amount: 120).transaction
    inflow = create_transaction(account: @card, amount: -120).transaction
    @function.call("transaction_id" => outflow.id, "counterpart_transaction_id" => inflow.id)

    result = assert_no_difference "Transfer.count" do
      @function.call("transaction_id" => outflow.id, "counterpart_transaction_id" => inflow.id)
    end

    assert_equal true, result[:success]
    assert_equal true, result[:already_matched]
  end

  test "matching to the same target account again is a no-op" do
    outflow = create_transaction(account: @checking, amount: 50).transaction
    @function.call("transaction_id" => outflow.id, "target_account_id" => @loan.id)

    result = assert_no_difference [ "Transfer.count", "Entry.count" ] do
      @function.call("transaction_id" => outflow.id, "target_account_id" => @loan.id)
    end

    assert_equal true, result[:already_matched]
  end

  test "reports already_linked with the transfer id, pointing pending auto-matches at review_transfer" do
    outflow = create_transaction(account: @checking, amount: 120).transaction
    inflow = create_transaction(account: @card, amount: -120).transaction
    pending = Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow, status: "pending")

    result = @function.call("transaction_id" => outflow.id, "target_account_id" => @loan.id)

    assert_equal false, result[:success]
    assert_equal "already_linked", result[:error]
    assert_equal pending.id, result[:transfer][:transfer_id]
    assert_match "review_transfer", result[:message]
  end

  test "requires exactly one of counterpart_transaction_id and target_account_id" do
    outflow = create_transaction(account: @checking, amount: 120).transaction

    [ {}, { "counterpart_transaction_id" => outflow.id, "target_account_id" => @loan.id } ].each do |extra|
      result = @function.call({ "transaction_id" => outflow.id }.merge(extra))
      assert_equal "invalid_arguments", result[:error]
    end
  end

  test "does not match into an account the user can only read" do
    # family_member has full control of the checking account but read-only on the card
    function = Assistant::Function::MatchTransfer.new(users(:family_member))
    outflow = create_transaction(account: @checking, amount: 120).transaction
    inflow = create_transaction(account: @card, amount: -120).transaction

    result = function.call("transaction_id" => outflow.id, "counterpart_transaction_id" => inflow.id)
    assert_equal "not_found", result[:error]

    result = function.call("transaction_id" => outflow.id, "target_account_id" => @card.id)
    assert_equal "account_not_found", result[:error]

    assert_nil outflow.reload.transfer
  end

  test "does not resolve another family's transaction" do
    outflow = create_transaction(account: @checking, amount: 120).transaction

    result = Assistant::Function::MatchTransfer.new(users(:josh)).call("transaction_id" => outflow.id, "target_account_id" => @loan.id)

    assert_equal "not_found", result[:error]
  end
end
