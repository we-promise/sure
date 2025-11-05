require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "should get index" do
    get accounts_url
    assert_response :success
  end

  test "should get show" do
    get account_url(@account)
    assert_response :success
  end

  test "should sync account" do
    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end

  test "should get sparkline" do
    get sparkline_account_url(@account)
    assert_response :success
  end

  test "destroys account" do
    delete account_url(@account)
    assert_redirected_to accounts_path
    assert_enqueued_with job: DestroyJob
    assert_equal "Account scheduled for deletion", flash[:notice]
  end

  test "syncing linked account triggers sync for all provider items" do
    plaid_account = plaid_accounts(:one)
    plaid_item = plaid_account.plaid_item
    AccountProvider.create!(account: @account, provider: plaid_account)

    # Reload to ensure the account has the provider association loaded
    @account.reload

    # Mock at the class level since controller loads account from DB
    Account.any_instance.expects(:syncing?).returns(false)
    PlaidItem.any_instance.expects(:syncing?).returns(false)
    PlaidItem.any_instance.expects(:sync_later).once

    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end

  test "syncing unlinked account calls account sync_later" do
    Account.any_instance.expects(:syncing?).returns(false)
    Account.any_instance.expects(:sync_later).once

    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end
end

require "test_helper"

class AccountsControllerSimplefinCtaTest < ActionDispatch::IntegrationTest
  fixtures :users, :families

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
  end

  test "when unlinked SFAs exist and manuals exist, shows setup button only" do
    item = SimplefinItem.create!(family: @family, name: "Conn", access_url: "https://example.com/access")
    # Unlinked SFA (no account and no provider link)
    item.simplefin_accounts.create!(name: "A", account_id: "sf_a", currency: "USD", current_balance: 1, account_type: "depository")
    # One manual account available
    Account.create!(family: @family, name: "Manual A", currency: "USD", balance: 0, accountable_type: "Depository", accountable: Depository.create!(subtype: "checking"))

    get accounts_path
    assert_response :success
    # Expect setup link present
    assert_includes @response.body, setup_accounts_simplefin_item_path(item)
    # Relink should be hidden until setup is done
    refute_includes @response.body, manual_relink_simplefin_item_path(item)
  end

  test "when SFAs exist and none unlinked and manuals exist, shows relink button" do
    item = SimplefinItem.create!(family: @family, name: "Conn2", access_url: "https://example.com/access")
    # Create a manual linked to SFA so unlinked count == 0
    sfa = item.simplefin_accounts.create!(name: "B", account_id: "sf_b", currency: "USD", current_balance: 1, account_type: "depository")
    linked = Account.create!(family: @family, name: "Linked", currency: "USD", balance: 0, accountable_type: "Depository", accountable: Depository.create!(subtype: "savings"))
    # Legacy association sufficient to count as linked
    sfa.update!(account: linked)

    # Also create another manual account to make manuals_exist true
    Account.create!(family: @family, name: "Manual B", currency: "USD", balance: 0, accountable_type: "Depository", accountable: Depository.create!(subtype: "checking"))

    get accounts_path
    assert_response :success
    # Expect relink link present
    assert_includes @response.body, manual_relink_simplefin_item_path(item)
    # Setup link should be absent because unlinked == 0
    refute_includes @response.body, setup_accounts_simplefin_item_path(item)
  end

  test "when no SFAs exist, shows neither CTA" do
    item = SimplefinItem.create!(family: @family, name: "Conn3", access_url: "https://example.com/access")

    get accounts_path
    assert_response :success
    refute_includes @response.body, setup_accounts_simplefin_item_path(item)
    refute_includes @response.body, manual_relink_simplefin_item_path(item)
  end
end
