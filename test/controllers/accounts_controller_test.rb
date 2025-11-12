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

  test "confirms unlink for linked account" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    get confirm_unlink_account_url(@account)
    assert_response :success
  end

  test "redirects when confirming unlink for unlinked account" do
    get confirm_unlink_account_url(@account)
    assert_redirected_to account_url(@account)
    assert_equal "Account is not linked to a provider", flash[:alert]
  end

  test "unlinks linked account successfully" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)
    @account.reload

    assert @account.linked?

    delete unlink_account_url(@account)
    @account.reload

    assert_not @account.linked?
    assert_redirected_to accounts_path
    assert_equal "Account unlinked successfully. It is now a manual account.", flash[:notice]
  end

  test "redirects when unlinking unlinked account" do
    delete unlink_account_url(@account)
    assert_redirected_to account_url(@account)
    assert_equal "Account is not linked to a provider", flash[:alert]
  end

  test "unlinked account can be deleted" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)
    @account.reload

    # Cannot delete while linked
    delete account_url(@account)
    assert_redirected_to account_url(@account)
    assert_equal "Cannot delete a linked account", flash[:alert]

    # Unlink the account
    delete unlink_account_url(@account)
    @account.reload

    # Now can delete
    delete account_url(@account)
    assert_redirected_to accounts_path
    assert_enqueued_with job: DestroyJob
    assert_equal "Account scheduled for deletion", flash[:notice]
  end
end
