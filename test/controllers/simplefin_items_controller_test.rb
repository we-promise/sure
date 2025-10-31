require "test_helper"

class SimplefinItemsControllerTest < ActionDispatch::IntegrationTest
  fixtures :users, :families
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test Connection",
      access_url: "https://example.com/test_access"
    )
  end

  test "should get index" do
    get simplefin_items_url
    assert_response :success
    assert_includes response.body, @simplefin_item.name
  end

  test "should get new" do
    get new_simplefin_item_url
    assert_response :success
  end

  test "should show simplefin item" do
    get simplefin_item_url(@simplefin_item)
    assert_response :success
  end

  test "should destroy simplefin item" do
    assert_difference("SimplefinItem.count", 0) do # doesn't actually delete immediately
      delete simplefin_item_url(@simplefin_item)
    end

    assert_redirected_to accounts_path
    @simplefin_item.reload
    assert @simplefin_item.scheduled_for_deletion?
  end

  test "should sync simplefin item" do
    post sync_simplefin_item_url(@simplefin_item)
    assert_redirected_to accounts_path
  end

  test "should get edit" do
    @simplefin_item.update!(status: :requires_update)
    get edit_simplefin_item_url(@simplefin_item)
    assert_response :success
  end

  test "should update simplefin item with valid token" do
    @simplefin_item.update!(status: :requires_update)

    # Mock the SimpleFin provider to prevent real API calls
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with("valid_token").returns("https://example.com/new_access")
    mock_provider.expects(:get_accounts).returns({ accounts: [] }).at_least_once
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least_once

    # Let the real create_simplefin_item! method run - don't mock it

    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "valid_token" }
    }

    assert_redirected_to accounts_path
    assert_match(/updated successfully/, flash[:notice])
    @simplefin_item.reload
    assert @simplefin_item.scheduled_for_deletion?
  end

  test "should handle update with invalid token" do
    @simplefin_item.update!(status: :requires_update)

    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "" }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Please enter a SimpleFin setup token"
  end

  test "should transfer accounts when updating simplefin item token" do
    @simplefin_item.update!(status: :requires_update)

    # Create old SimpleFin accounts linked to Maybe accounts
    old_simplefin_account1 = @simplefin_item.simplefin_accounts.create!(
      name: "Test Checking",
      account_id: "sf_account_123",
      currency: "USD",
      current_balance: 1000,
      account_type: "depository"
    )
    old_simplefin_account2 = @simplefin_item.simplefin_accounts.create!(
      name: "Test Savings",
      account_id: "sf_account_456",
      currency: "USD",
      current_balance: 5000,
      account_type: "depository"
    )

    # Create Maybe accounts linked to the SimpleFin accounts
    maybe_account1 = Account.create!(
      family: @family,
      name: "Checking Account",
      balance: 1000,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "checking"),
      simplefin_account_id: old_simplefin_account1.id
    )
    maybe_account2 = Account.create!(
      family: @family,
      name: "Savings Account",
      balance: 5000,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "savings"),
      simplefin_account_id: old_simplefin_account2.id
    )

    # Update old SimpleFin accounts to reference the Maybe accounts
    old_simplefin_account1.update!(account: maybe_account1)
    old_simplefin_account2.update!(account: maybe_account2)

    # Mock only the external API calls, let business logic run
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with("valid_token").returns("https://example.com/new_access")
    mock_provider.expects(:get_accounts).returns({
      accounts: [
        {
          id: "sf_account_123",
          name: "Test Checking",
          type: "depository",
          currency: "USD",
          balance: 1000,
          transactions: []
        },
        {
          id: "sf_account_456",
          name: "Test Savings",
          type: "depository",
          currency: "USD",
          balance: 5000,
          transactions: []
        }
      ]
    }).at_least_once
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least_once

    # Perform the update
    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "valid_token" }
    }

    assert_redirected_to accounts_path
    assert_match(/updated successfully/, flash[:notice])

    # Verify accounts were transferred to new SimpleFin accounts
    assert Account.exists?(maybe_account1.id), "maybe_account1 should still exist"
    assert Account.exists?(maybe_account2.id), "maybe_account2 should still exist"

    maybe_account1.reload
    maybe_account2.reload

    # Find the new SimpleFin item that was created
    new_simplefin_item = @family.simplefin_items.where.not(id: @simplefin_item.id).first
    assert_not_nil new_simplefin_item, "New SimpleFin item should have been created"

    new_sf_account1 = new_simplefin_item.simplefin_accounts.find_by(account_id: "sf_account_123")
    new_sf_account2 = new_simplefin_item.simplefin_accounts.find_by(account_id: "sf_account_456")

    assert_not_nil new_sf_account1, "New SimpleFin account with ID sf_account_123 should exist"
    assert_not_nil new_sf_account2, "New SimpleFin account with ID sf_account_456 should exist"

    assert_equal new_sf_account1.id, maybe_account1.simplefin_account_id
    assert_equal new_sf_account2.id, maybe_account2.simplefin_account_id

    # Verify old SimpleFin accounts no longer reference Maybe accounts
    old_simplefin_account1.reload
    old_simplefin_account2.reload
    assert_nil old_simplefin_account1.current_account
    assert_nil old_simplefin_account2.current_account

    # Verify old SimpleFin item is scheduled for deletion
    @simplefin_item.reload
    assert @simplefin_item.scheduled_for_deletion?
  end

  test "should handle partial account matching during token update" do
    @simplefin_item.update!(status: :requires_update)

    # Create old SimpleFin account
    old_simplefin_account = @simplefin_item.simplefin_accounts.create!(
      name: "Test Checking",
      account_id: "sf_account_123",
      currency: "USD",
      current_balance: 1000,
      account_type: "depository"
    )

    # Create Maybe account linked to the SimpleFin account
    maybe_account = Account.create!(
      family: @family,
      name: "Checking Account",
      balance: 1000,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "checking"),
      simplefin_account_id: old_simplefin_account.id
    )
    old_simplefin_account.update!(account: maybe_account)

    # Mock only the external API calls, let business logic run
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with("valid_token").returns("https://example.com/new_access")
    # Return empty accounts list to simulate account was removed from bank
    mock_provider.expects(:get_accounts).returns({ accounts: [] }).at_least_once
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least_once

    # Perform update
    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "valid_token" }
    }

    assert_redirected_to accounts_path

    # Verify Maybe account still linked to old SimpleFin account (no transfer occurred)
    maybe_account.reload
    old_simplefin_account.reload
    assert_equal old_simplefin_account.id, maybe_account.simplefin_account_id
    assert_equal maybe_account, old_simplefin_account.current_account

    # Old item still scheduled for deletion
    @simplefin_item.reload
    assert @simplefin_item.scheduled_for_deletion?
  end

  test "select_existing_account redirects when no available simplefin accounts" do
    account = accounts(:depository)

    get select_existing_account_simplefin_items_url(account_id: account.id)
    assert_redirected_to account_path(account)
    assert_equal "No available SimpleFIN accounts to link. Please connect a new SimpleFIN account first.", flash[:alert]
  end
  test "destroy should unlink provider links and legacy fk" do
    # Create SFA and linked Account with AccountProvider
    sfa = @simplefin_item.simplefin_accounts.create!(name: "Linked", account_id: "sf_link_1", currency: "USD", current_balance: 1, account_type: "depository")
    acct = Account.create!(family: @family, name: "Manual A", currency: "USD", balance: 0, accountable_type: "Depository", accountable: Depository.create!(subtype: "checking"), simplefin_account_id: sfa.id)
    AccountProvider.create!(account: acct, provider_type: "SimplefinAccount", provider_id: sfa.id)

    delete simplefin_item_url(@simplefin_item)
    assert_redirected_to accounts_path

    # Links are removed immediately even though deletion is scheduled
    assert_nil acct.reload.simplefin_account_id
    assert_equal 0, AccountProvider.where(provider_type: "SimplefinAccount", provider_id: sfa.id).count
  end

  test "apply_relink links pairs in one pass and avoids duplicates" do
    # Manual account existing
    manual = Account.create!(family: @family, name: "Quicksilver", currency: "USD", balance: 0, accountable_type: "CreditCard", accountable: CreditCard.create!)

    # SimpleFin account with same name (candidate by name)
    sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Quicksilver", account_id: "sf_qs_1", currency: "USD", current_balance: -10, account_type: "credit"
    )

    # Simulate provider-linked duplicate account that should be removed after relink
    dup_acct = Account.create!(family: @family, name: "Quicksilver (dup)", currency: "USD", balance: 0, accountable_type: "CreditCard", accountable: CreditCard.create!)
    AccountProvider.create!(account: dup_acct, provider_type: "SimplefinAccount", provider_id: sfa.id)

    post apply_relink_simplefin_item_url(@simplefin_item), params: {
      pairs: [ { sfa_id: sfa.id, manual_id: manual.id, checked: "1" } ]
    }, as: :json
    assert_response :success

    # Provider link should now point to manual, and duplicate account should be gone after cleanup
    ap = AccountProvider.find_by(provider_type: "SimplefinAccount", provider_id: sfa.id)
    assert_equal manual.id, ap.account_id
    assert_raises(ActiveRecord::RecordNotFound) { dup_acct.reload }
  end

  test "complete_account_setup creates accounts only for truly unlinked SFAs" do
    # Linked SFA (should be ignored by setup)
    linked_sfa = @simplefin_item.simplefin_accounts.create!(name: "Linked", account_id: "sf_l_1", currency: "USD", current_balance: 5, account_type: "depository")
    linked_acct = Account.create!(family: @family, name: "Already Linked", currency: "USD", balance: 0, accountable_type: "Depository", accountable: Depository.create!(subtype: "savings"))
    linked_sfa.update!(account: linked_acct)

    # Unlinked SFA (should be created via setup)
    unlinked_sfa = @simplefin_item.simplefin_accounts.create!(name: "New CC", account_id: "sf_cc_1", currency: "USD", current_balance: -20, account_type: "credit")

    post complete_account_setup_simplefin_item_url(@simplefin_item), params: {
      account_types: { unlinked_sfa.id => "CreditCard" },
      account_subtypes: { unlinked_sfa.id => "credit_card" },
      sync_start_date: Date.today.to_s
    }

    assert_redirected_to accounts_path
    assert_not @simplefin_item.reload.pending_account_setup

    # Linked one unchanged, unlinked now has an account
    linked_sfa.reload
    unlinked_sfa.reload
    # The previously linked SFA should still point to the same Maybe account via legacy FK or provider link
    assert_equal linked_acct.id, linked_sfa.account&.id
    # The newly created account for the unlinked SFA should now exist
    assert_not_nil unlinked_sfa.account_id
  end
end
