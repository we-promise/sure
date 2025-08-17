require "test_helper"

class SimplefinItemsControllerTest < ActionDispatch::IntegrationTest
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

    # Mock the SimpleFin provider
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with("valid_token").returns("https://example.com/new_access")
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least(1)

    # Mock the SimpleFin provider to prevent real API calls
    mock_provider.expects(:get_accounts).returns({ accounts: [] }).at_least_once

    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "valid_token" }
    }

    assert_redirected_to accounts_path
    assert_match(/updated successfully/, flash[:notice])
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

    # Create new SimpleFin item that will be returned
    new_simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Updated Connection",
      access_url: "https://example.com/new_access"
    )

    # Mock the provider and family methods
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with("valid_token").returns("https://example.com/new_access")
    Provider::Simplefin.expects(:new).returns(mock_provider)

    @family.expects(:create_simplefin_item!).with(
      setup_token: "valid_token",
      item_name: @simplefin_item.name
    ).returns(new_simplefin_item)

    # Mock the import to create matching SimpleFin accounts
    new_simplefin_item.expects(:import_latest_simplefin_data).once.returns(nil).tap do
      # Simulate what import_latest_simplefin_data would do - create matching accounts
      new_simplefin_item.simplefin_accounts.create!(
        name: "Test Checking",
        account_id: "sf_account_123", # Same account_id for matching
        currency: "USD",
        current_balance: 1000,
        account_type: "depository"
      )
      new_simplefin_item.simplefin_accounts.create!(
        name: "Test Savings",
        account_id: "sf_account_456", # Same account_id for matching  
        currency: "USD", 
        current_balance: 5000,
        account_type: "depository"
      )
    end

    # Perform the update
    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "valid_token" }
    }

    assert_redirected_to accounts_path
    assert_match(/updated successfully/, flash[:notice])

    # Verify accounts were transferred to new SimpleFin accounts
    maybe_account1.reload
    maybe_account2.reload
    
    new_sf_account1 = new_simplefin_item.simplefin_accounts.find_by(account_id: "sf_account_123")
    new_sf_account2 = new_simplefin_item.simplefin_accounts.find_by(account_id: "sf_account_456")
    
    assert_equal new_sf_account1.id, maybe_account1.simplefin_account_id
    assert_equal new_sf_account2.id, maybe_account2.simplefin_account_id

    # Verify old SimpleFin accounts no longer reference Maybe accounts
    old_simplefin_account1.reload
    old_simplefin_account2.reload
    assert_nil old_simplefin_account1.account
    assert_nil old_simplefin_account2.account

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

    # Create new SimpleFin item 
    new_simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Updated Connection",
      access_url: "https://example.com/new_access"
    )

    # Mock provider
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with("valid_token").returns("https://example.com/new_access")
    Provider::Simplefin.expects(:new).returns(mock_provider)

    @family.expects(:create_simplefin_item!).returns(new_simplefin_item)

    # Mock import that creates NO matching accounts (account was removed from bank)
    new_simplefin_item.expects(:import_latest_simplefin_data).once.returns(nil)
    # Don't create any matching SimpleFin accounts to simulate account not found

    # Perform update
    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "valid_token" }
    }

    assert_redirected_to accounts_path

    # Verify Maybe account still linked to old SimpleFin account (no transfer occurred)
    maybe_account.reload
    old_simplefin_account.reload
    assert_equal old_simplefin_account.id, maybe_account.simplefin_account_id
    assert_equal maybe_account, old_simplefin_account.account

    # Old item still scheduled for deletion
    @simplefin_item.reload  
    assert @simplefin_item.scheduled_for_deletion?
  end
end
