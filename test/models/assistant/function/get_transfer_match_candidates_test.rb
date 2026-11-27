require "test_helper"

class Assistant::Function::GetTransferMatchCandidatesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::GetTransferMatchCandidates.new(@user)
    @checking = accounts(:depository)
    @card = accounts(:credit_card)
  end

  test "lists candidates and flags previously rejected pairings" do
    outflow = create_transaction(account: @checking, amount: 64, date: Date.current).transaction
    fresh = create_transaction(account: @card, amount: -64, date: 1.day.ago.to_date).transaction
    rejected = create_transaction(account: accounts(:other_liability), amount: -64, date: 2.days.ago.to_date).transaction
    RejectedTransfer.create!(outflow_transaction: outflow, inflow_transaction: rejected)

    result = @function.call("transaction_id" => outflow.id)

    assert_equal true, result[:success]
    assert_nil result[:transfer]
    by_id = result[:candidates].index_by { |c| c[:transaction_id] }
    assert_equal [ fresh.id, rejected.id ].sort, by_id.keys.sort
    assert_equal false, by_id[fresh.id][:previously_rejected]
    assert_equal true, by_id[rejected.id][:previously_rejected]
    assert_equal 1, by_id[fresh.id][:days_apart]
    assert_equal "inflow", by_id[fresh.id][:direction]
  end

  test "returns the current transfer, including a pending auto-match" do
    outflow = create_transaction(account: @checking, amount: 64).transaction
    inflow = create_transaction(account: @card, amount: -64).transaction
    transfer = Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow, status: "pending")

    result = @function.call("transaction_id" => outflow.id)

    assert_equal transfer.id, result[:transfer][:transfer_id]
    assert_equal "pending", result[:transfer][:status]
    assert_equal inflow.id, result[:transfer][:counterpart][:transaction_id]
    assert_empty result[:candidates]
  end

  test "hides candidates in accounts the user cannot access" do
    member = users(:family_member)
    private_account = families(:dylan_family).accounts.create!(
      name: "Admin private", balance: 0, currency: "USD", accountable: Depository.new, owner: @user
    )
    outflow = create_transaction(account: @checking, amount: 64).transaction
    create_transaction(account: private_account, amount: -64)

    result = Assistant::Function::GetTransferMatchCandidates.new(member).call("transaction_id" => outflow.id)

    assert_empty result[:candidates]
  end

  test "returns not_found for another family's transaction" do
    outflow = create_transaction(account: @checking, amount: 64).transaction

    result = Assistant::Function::GetTransferMatchCandidates.new(users(:josh)).call("transaction_id" => outflow.id)

    assert_equal "not_found", result[:error]
  end
end
