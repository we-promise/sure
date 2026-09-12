require "test_helper"

class AutoMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
  end

  test "index lists pending auto-matched transfers for the family" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    @family.auto_match_transfers!

    get auto_matches_url
    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(outflow_entry.transaction.transfer)}"
  end

  test "index does not include transfers already confirmed" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:credit_card), amount: -500)
    @family.auto_match_transfers!
    outflow_entry.transaction.transfer.confirm!

    get auto_matches_url
    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(outflow_entry.transaction.transfer)}", false
  end

  test "index excludes matches where the outflow account is private to another family member" do
    # other_asset is owned by family_admin and not shared with family_member;
    # depository is shared with family_member (full_control).
    outflow_entry = create_transaction(date: Date.current, account: accounts(:other_asset), amount: 500)
    inflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: -500)
    @family.auto_match_transfers!

    sign_in users(:family_member)
    get auto_matches_url
    assert_response :success
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(outflow_entry.transaction.transfer)}", false
  end

  test "update_settings disables auto match" do
    patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "true" }
    assert_redirected_to auto_matches_url
    assert @family.reload.auto_match_transfers_disabled?
  end

  test "update_settings re-enables auto match" do
    @family.update!(auto_match_transfers_disabled: true)

    patch update_settings_auto_matches_url, params: { auto_match_transfers_disabled: "false" }
    assert_redirected_to auto_matches_url
    assert_not @family.reload.auto_match_transfers_disabled?
  end
end
