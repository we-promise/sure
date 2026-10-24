require "test_helper"

class TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include GoalPledgeTestHelper

  setup do
    sign_in @user = users(:family_admin)
  end

  test "new only offers candidates from accounts the user can write to" do
    loan = accounts(:loan)
    loan.update!(owner: users(:family_member))
    # Accessible but not writable: candidates must be filtered by write access
    loan.account_shares.create!(user: @user, permission: "read_only")

    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))
    hidden_inflow = create_transaction(amount: -100, account: loan, name: "Hidden member inflow")
    visible_inflow = create_transaction(amount: -100, account: accounts(:investment), name: "Visible own inflow")

    get new_transaction_transfer_match_path(outflow_entry)

    assert_response :success
    assert_select "option[value=?]", visible_inflow.id
    assert_select "option[value=?]", hidden_inflow.id, count: 0
  end

  test "matches existing transaction and creates transfer" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))
    outflow_transaction = create_transaction(amount: -100, account: accounts(:investment))

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "existing",
          matched_entry_id: outflow_transaction.id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "creates transfer for target account" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))

    assert_difference [ "Transfer.count", "Entry.count", "Transaction.count" ], 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "new",
          target_account_id: accounts(:investment).id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "new transfer entry is protected from provider sync" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    transfer = Transfer.order(created_at: :desc).first
    new_entry = transfer.inflow_transaction.entry

    assert new_entry.user_modified?, "New transfer entry should be marked as user_modified to protect from provider sync"
  end

  test "assigns investment_contribution kind and category for investment destination" do
    # Outflow from depository (positive amount), target is investment
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    outflow_entry.reload
    outflow_txn = outflow_entry.entryable

    assert_equal "investment_contribution", outflow_txn.kind

    category = @user.family.investment_contributions_category
    assert_equal category, outflow_txn.category
  end

  # we-promise/sure#4226: marking a synced bank outflow as a transfer to a
  # manual account creates the deposit there, which must resolve its pledge.
  test "matching an outflow to a new inflow on a pledged account resolves the pledge" do
    investment = accounts(:investment)
    pledge = open_transfer_pledge(investment, amount: 120)
    outflow = create_transaction(amount: 120, account: accounts(:depository), name: "To brokerage")

    post transaction_transfer_match_path(outflow), params: {
      transfer_match: { method: "new", target_account_id: investment.id }
    }

    transfer = Transfer.find_by!(outflow_transaction_id: outflow.transaction.id)
    assert_equal transfer.inflow_transaction.id, pledge.reload.matched_transaction_id
  end

  test "matching an inflow to a new outflow leaves the inflow account's pledge open" do
    pledge = goal_pledges(:open_transfer)
    inflow = create_transaction(amount: -200, account: pledge.account, name: "From brokerage")

    post transaction_transfer_match_path(inflow), params: {
      transfer_match: { method: "new", target_account_id: accounts(:investment).id }
    }

    assert_equal "open", pledge.reload.status
  end
end
