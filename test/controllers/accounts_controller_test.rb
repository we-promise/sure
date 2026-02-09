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
    assert_equal "Depository account scheduled for deletion", flash[:notice]
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

  test "unlinks linked account successfully with new system" do
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

  test "unlinks linked account successfully with legacy system" do
    plaid_account = plaid_accounts(:one)
    @account.update!(plaid_account_id: plaid_account.id)
    @account.reload

    assert @account.linked?

    delete unlink_account_url(@account)
    @account.reload

    assert_not @account.linked?
    assert_nil @account.plaid_account_id
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
    assert_equal "Cannot delete a linked account. Please unlink it first.", flash[:alert]

    # Unlink the account
    delete unlink_account_url(@account)
    @account.reload

    # Now can delete
    delete account_url(@account)
    assert_redirected_to accounts_path
    assert_enqueued_with job: DestroyJob
    assert_equal "Depository account scheduled for deletion", flash[:notice]
  end

  test "disabling an account keeps it visible on index" do
    @account.disable!

    get accounts_path

    assert_response :success
    assert_includes @response.body, @account.name
    assert_includes @response.body, "account_#{@account.id}_active"
  end

  test "toggle_active disables and re-enables an account" do
    patch toggle_active_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.disabled?

    patch toggle_active_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.active?
  end

  test "select_provider shows available providers" do
    get select_provider_account_url(@account)
    assert_response :success
  end

  test "select_provider redirects for already linked account" do
    plaid_account = plaid_accounts(:one)
    AccountProvider.create!(account: @account, provider: plaid_account)

    get select_provider_account_url(@account)
    assert_redirected_to account_url(@account)
    assert_equal "Account is already linked to a provider", flash[:alert]
  end

  test "unlink preserves SnaptradeAccount record" do
    snaptrade_account = snaptrade_accounts(:fidelity_401k)
    investment = accounts(:investment)
    AccountProvider.create!(account: investment, provider: snaptrade_account)
    investment.reload

    assert investment.linked?

    delete unlink_account_url(investment)
    investment.reload

    assert_not investment.linked?
    assert_redirected_to accounts_path
    # SnaptradeAccount should still exist (not destroyed)
    assert SnaptradeAccount.exists?(snaptrade_account.id), "SnaptradeAccount should be preserved after unlink"
    # But AccountProvider should be gone
    assert_not AccountProvider.exists?(provider_type: "SnaptradeAccount", provider_id: snaptrade_account.id)
  end

  test "unlink does not enqueue SnapTrade cleanup job" do
    snaptrade_account = snaptrade_accounts(:fidelity_401k)
    investment = accounts(:investment)
    AccountProvider.create!(account: investment, provider: snaptrade_account)
    investment.reload

    assert_no_enqueued_jobs(only: SnaptradeConnectionCleanupJob) do
      delete unlink_account_url(investment)
    end
  end

  test "unlink detaches holdings from SnapTrade provider" do
    snaptrade_account = snaptrade_accounts(:fidelity_401k)
    investment = accounts(:investment)
    ap = AccountProvider.create!(account: investment, provider: snaptrade_account)

    # Assign a holding to this provider
    holding = holdings(:one)
    holding.update!(account_provider: ap)

    delete unlink_account_url(investment)
    holding.reload

    assert_nil holding.account_provider_id, "Holding should be detached from provider after unlink"
  end
end

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
    # Relink modal (SimpleFin-specific) should not be present anymore
    refute_includes @response.body, "Link existing accounts"
  end

  test "when SFAs exist and none unlinked and manuals exist, no relink modal is shown (unified flow)" do
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
    # The SimpleFin-specific relink modal is removed in favor of unified provider flow
    refute_includes @response.body, "Link existing accounts"
  end

  test "when no SFAs exist, shows neither CTA" do
    item = SimplefinItem.create!(family: @family, name: "Conn3", access_url: "https://example.com/access")

    get accounts_path
    assert_response :success
    refute_includes @response.body, setup_accounts_simplefin_item_path(item)
    refute_includes @response.body, "Link existing accounts"
  end
end
