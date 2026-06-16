require "test_helper"

class CardChangeReimbursementsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account_a = accounts(:depository)
    @account_b = accounts(:credit_card)
  end

  test "index renders" do
    get card_change_reimbursements_path
    assert_response :success
  end

  test "confirm links charge and reimbursement as a card_change transfer and keeps the original" do
    original = create_transaction(account: @account_a, amount: 412, date: 90.days.ago.to_date, kind: "standard")
    outflow = create_transaction(account: @account_b, amount: 412, date: 30.days.ago.to_date, kind: "standard")
    inflow = create_transaction(account: @account_a, amount: -412, date: 25.days.ago.to_date, kind: "standard")

    assert_difference "Transfer.count", 1 do
      post confirm_card_change_reimbursement_path(inflow.entryable_id, outflow_id: outflow.entryable_id)
    end

    assert_redirected_to card_change_reimbursements_path

    transfer = Transfer.order(created_at: :desc).first
    assert_equal "card_change", transfer.kind
    assert_equal "confirmed", transfer.status

    # Charge + reimbursement are now transfers, excluded from spending analytics
    assert_equal "funds_movement", Transaction.find(inflow.entryable_id).kind
    assert_equal "funds_movement", Transaction.find(outflow.entryable_id).kind

    # Original purchase is untouched and remains a normal expense
    assert_equal "standard", Transaction.find(original.entryable_id).kind
  end

  test "dismiss records a rejected transfer" do
    outflow = create_transaction(account: @account_b, amount: 412, date: 30.days.ago.to_date)
    inflow = create_transaction(account: @account_a, amount: -412, date: 25.days.ago.to_date)

    assert_difference "RejectedTransfer.count", 1 do
      post dismiss_card_change_reimbursement_path(inflow.entryable_id, outflow_id: outflow.entryable_id)
    end

    assert_redirected_to card_change_reimbursements_path
  end
end
