require "test_helper"

class SimplefinItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
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

  test "balances enqueues SyncJob and returns sync id as JSON" do
    # Expect a Sync to be enqueued via SyncJob
    SyncJob.expects(:perform_later).with do |sync, opts|
      sync.is_a?(Sync) && opts.is_a?(Hash) && opts[:balances_only] == true
    end.once

    post balances_simplefin_item_url(@simplefin_item, format: :json)

    assert_response :success
    body = JSON.parse(@response.body)
    assert_equal true, body["ok"], "expected ok: true"
    assert body["sync_id"].present?, "expected sync_id to be present"
  end

  test "relink does not disable a previously linked account that still has other provider links" do
    # Create two manual accounts A and B
    account_a = Account.create!(
      family: @family,
      name: "Manual A",
      balance: 0,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "checking")
    )

    account_b = Account.create!(
      family: @family,
      name: "Manual B",
      balance: 0,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "savings")
    )

    # Create a SimpleFIN account under the same item
    sfa_primary = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "SF A",
      account_id: "sf_a",
      account_type: "depository",
      currency: "USD",
      current_balance: 0
    )

    # Link the primary SimpleFIN provider to account A via AccountProvider (legacy link cleared by action)
    AccountProvider.create!(account: account_a, provider: sfa_primary)

    # Also link a different provider TYPE (Plaid) to account A so it is NOT orphaned
    plaid_item = PlaidItem.create!(family: @family, name: "Plaid Conn", access_token: "test-token", plaid_id: "test-plaid-id")
    plaid_acct = PlaidAccount.create!(
      plaid_item: plaid_item,
      plaid_id: "test-plaid-acct",
      name: "Plaid A",
      plaid_type: "depository",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: account_a, provider: plaid_acct)

    # Perform relink: point sfa_primary at account B
    post link_existing_account_simplefin_items_path, params: {
      account_id: account_b.id,
      simplefin_account_id: sfa_primary.id
    }

    assert_response :see_other

    # Reload and assert: account A should not be hidden because it has another provider link
    account_a.reload
    assert account_a.account_providers.any?, "expected previous account to still have provider links"
    refute_equal "pending_deletion", account_a.status, "previous account should not be hidden when still linked to other providers"

    # And the AccountProvider for sfa_primary should now point to account B
    ap = AccountProvider.find_by(provider: sfa_primary)
    assert_equal account_b.id, ap.account_id
  end

  test "relink hides a previously linked orphaned duplicate account" do
    account_a = Account.create!(
      family: @family,
      name: "Duplicate A",
      balance: 0,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "checking")
    )

    account_b = Account.create!(
      family: @family,
      name: "Target B",
      balance: 0,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "savings")
    )

    sfa = @simplefin_item.simplefin_accounts.create!(
      name: "SF For Duplicate",
      account_id: "sf_dup_1",
      account_type: "depository",
      currency: "USD",
      current_balance: 0
    )

    AccountProvider.create!(account: account_a, provider: sfa)

    post link_existing_account_simplefin_items_path, params: {
      account_id: account_b.id,
      simplefin_account_id: sfa.id
    }

    assert_response :see_other

    account_a.reload
    assert_equal "pending_deletion", account_a.status, "expected orphaned duplicate to be hidden after relink"
  end

  test "should get edit" do
    @simplefin_item.update!(status: :requires_update)
    get edit_simplefin_item_url(@simplefin_item)
    assert_response :success
  end

  test "should update simplefin item with valid token" do
    @simplefin_item.update!(status: :requires_update)

    token = Base64.strict_encode64("https://example.com/claim")

    SimplefinConnectionUpdateJob.expects(:perform_later).with(
      family_id: @family.id,
      old_simplefin_item_id: @simplefin_item.id,
      setup_token: token
    ).once

    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: token }
    }

    assert_redirected_to accounts_path
    assert_equal "SimpleFIN connection updated.", flash[:notice]
  end

  test "should handle update with invalid token" do
    @simplefin_item.update!(status: :requires_update)

    patch simplefin_item_url(@simplefin_item), params: {
      simplefin_item: { setup_token: "" }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("simplefin_items.update.errors.blank_token", default: "Please enter a SimpleFIN setup token")
  end

  test "should transfer accounts when updating simplefin item token" do
    @simplefin_item.update!(status: :requires_update)

    token = Base64.strict_encode64("https://example.com/claim")

    # Create old SimpleFIN accounts linked to Maybe accounts
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

    # Create Maybe accounts linked to the SimpleFIN accounts
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

    # Update old SimpleFIN accounts to reference the Maybe accounts
    old_simplefin_account1.update!(account: maybe_account1)
    old_simplefin_account2.update!(account: maybe_account2)

    # Mock only the external API calls, let business logic run
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with(token).returns("https://example.com/new_access")
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

    # Perform the update (async job), but execute enqueued jobs inline so we can
    # assert the link transfers.
    perform_enqueued_jobs(only: SimplefinConnectionUpdateJob) do
      patch simplefin_item_url(@simplefin_item), params: {
        simplefin_item: { setup_token: token }
      }
    end

    assert_redirected_to accounts_path
    assert_equal "SimpleFIN connection updated.", flash[:notice]

    # Verify accounts were transferred to new SimpleFIN accounts
    assert Account.exists?(maybe_account1.id), "maybe_account1 should still exist"
    assert Account.exists?(maybe_account2.id), "maybe_account2 should still exist"

    maybe_account1.reload
    maybe_account2.reload

    # Find the new SimpleFIN item that was created
    new_simplefin_item = @family.simplefin_items.where.not(id: @simplefin_item.id).first
    assert_not_nil new_simplefin_item, "New SimpleFIN item should have been created"

    new_sf_account1 = new_simplefin_item.simplefin_accounts.find_by(account_id: "sf_account_123")
    new_sf_account2 = new_simplefin_item.simplefin_accounts.find_by(account_id: "sf_account_456")

    assert_not_nil new_sf_account1, "New SimpleFIN account with ID sf_account_123 should exist"
    assert_not_nil new_sf_account2, "New SimpleFIN account with ID sf_account_456 should exist"

    assert_equal new_sf_account1.id, maybe_account1.simplefin_account_id
    assert_equal new_sf_account2.id, maybe_account2.simplefin_account_id

    # The old item will be deleted asynchronously; until then, legacy links should be moved.

    # Verify old SimpleFIN item is scheduled for deletion
    @simplefin_item.reload
    assert @simplefin_item.scheduled_for_deletion?
  end

  test "should handle partial account matching during token update" do
    @simplefin_item.update!(status: :requires_update)

    token = Base64.strict_encode64("https://example.com/claim")

    # Create old SimpleFIN account
    old_simplefin_account = @simplefin_item.simplefin_accounts.create!(
      name: "Test Checking",
      account_id: "sf_account_123",
      currency: "USD",
      current_balance: 1000,
      account_type: "depository"
    )

    # Create Maybe account linked to the SimpleFIN account
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
    mock_provider.expects(:claim_access_url).with(token).returns("https://example.com/new_access")
    # Return empty accounts list to simulate account was removed from bank
    mock_provider.expects(:get_accounts).returns({ accounts: [] }).at_least_once
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least_once

    # Perform update
    perform_enqueued_jobs(only: SimplefinConnectionUpdateJob) do
      patch simplefin_item_url(@simplefin_item), params: {
        simplefin_item: { setup_token: token }
      }
    end

    assert_redirected_to accounts_path

    # Verify Maybe account still linked to old SimpleFIN account (no transfer occurred)
    maybe_account.reload
    old_simplefin_account.reload
    assert_equal old_simplefin_account.id, maybe_account.simplefin_account_id
    assert_equal maybe_account, old_simplefin_account.current_account

    # Old item still scheduled for deletion
    @simplefin_item.reload
    assert @simplefin_item.scheduled_for_deletion?
  end

  test "select_existing_account renders empty-state modal when no simplefin accounts exist" do
    account = accounts(:depository)

    get select_existing_account_simplefin_items_url(account_id: account.id)
    assert_response :success
    assert_includes @response.body, "No SimpleFIN accounts found for this family."
  end

  test "select_existing_account lists simplefin accounts even when they are already linked" do
    account = accounts(:depository)

    sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Linked SF",
      account_id: "sf_linked_123",
      currency: "USD",
      current_balance: 10,
      account_type: "depository"
    )

    linked_account = Account.create!(
      family: @family,
      name: "Existing Linked Account",
      currency: "USD",
      balance: 0,
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "checking")
    )
    # Model the pre-relink state: the provider account is linked to a newly set up duplicate
    # via the legacy FK, and may also have an AccountProvider.
    linked_account.update!(simplefin_account_id: sfa.id)
    sfa.update!(account: linked_account)
    AccountProvider.create!(account: linked_account, provider: sfa)

    get select_existing_account_simplefin_items_url(account_id: account.id)
    assert_response :success
    assert_includes @response.body, "Linked SF"
    assert_includes @response.body, "Currently linked to: Existing Linked Account"
  end

  test "select_existing_account hides simplefin accounts after they have been relinked" do
    account = accounts(:depository)

    sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Relinked SF",
      account_id: "sf_relinked_123",
      currency: "USD",
      current_balance: 10,
      account_type: "depository"
    )

    # Simulate post-relink state: legacy link cleared, AccountProvider exists.
    linked_account = Account.create!(
      family: @family,
      name: "Final Linked Account",
      currency: "USD",
      balance: 0,
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "checking")
    )
    AccountProvider.create!(account: linked_account, provider: sfa)

    get select_existing_account_simplefin_items_url(account_id: account.id)
    assert_response :success
    refute_includes @response.body, "Relinked SF"
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
  test "update redirects to accounts after setup without forcing a modal" do
    @simplefin_item.update!(status: :requires_update)

    token = Base64.strict_encode64("https://example.com/claim")

    SimplefinConnectionUpdateJob.expects(:perform_later).with(
      family_id: @family.id,
      old_simplefin_item_id: @simplefin_item.id,
      setup_token: token
    ).once

    patch simplefin_item_url(@simplefin_item), params: { simplefin_item: { setup_token: token } }

    assert_redirected_to accounts_path
  end

  test "create does not auto-open when no candidates or unlinked" do
    # Mock provider interactions for item creation (no immediate account import on create)
    mock_provider = mock()
    token = Base64.strict_encode64("https://example.com/claim")
    mock_provider.expects(:claim_access_url).with(token).returns("https://example.com/new_access")
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least_once

    post simplefin_items_url, params: { simplefin_item: { setup_token: token } }

    assert_response :redirect
    uri = URI(response.redirect_url)
    assert_equal "/accounts", uri.path
    q = Rack::Utils.parse_nested_query(uri.query)
    assert !q.key?("open_relink_for"), "did not expect auto-open when nothing actionable"
  end

  test "update does not auto-open when no SFAs present" do
    @simplefin_item.update!(status: :requires_update)

    token = Base64.strict_encode64("https://example.com/claim")

    SimplefinConnectionUpdateJob.expects(:perform_later).with(
      family_id: @family.id,
      old_simplefin_item_id: @simplefin_item.id,
      setup_token: token
    ).once

    patch simplefin_item_url(@simplefin_item), params: { simplefin_item: { setup_token: token } }

    assert_response :redirect
    uri = URI(response.redirect_url)
    assert_equal "/accounts", uri.path
    q = Rack::Utils.parse_nested_query(uri.query)
    assert !q.key?("open_relink_for"), "did not expect auto-open when update produced no SFAs/candidates"
  end

  # Stale account detection and handling tests

  test "setup_accounts detects stale accounts not in upstream API" do
    # Create a linked SimpleFIN account
    linked_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Old Bitcoin",
      account_id: "stale_btc_123",
      currency: "USD",
      current_balance: 0,
      account_type: "crypto"
    )
    linked_account = Account.create!(
      family: @family,
      name: "Old Bitcoin",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!
    )
    linked_sfa.update!(account: linked_account)
    linked_account.update!(simplefin_account_id: linked_sfa.id)

    # Set raw_payload to simulate upstream API response WITHOUT the stale account
    @simplefin_item.update!(raw_payload: {
      accounts: [
        { id: "active_cash_456", name: "Cash", balance: 1000, currency: "USD" }
      ]
    })

    get setup_accounts_simplefin_item_url(@simplefin_item)
    assert_response :success

    # Should detect the stale account
    assert_includes response.body, "Accounts No Longer in SimpleFIN"
    assert_includes response.body, "Old Bitcoin"
  end

  test "complete_account_setup deletes stale account when delete action selected" do
    # Create a linked SimpleFIN account that will be stale
    stale_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Stale Account",
      account_id: "stale_123",
      currency: "USD",
      current_balance: 0,
      account_type: "depository"
    )
    stale_account = Account.create!(
      family: @family,
      name: "Stale Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.create!(subtype: "checking")
    )
    stale_sfa.update!(account: stale_account)
    stale_account.update!(simplefin_account_id: stale_sfa.id)

    # Add a transaction to the account
    Entry.create!(
      account: stale_account,
      name: "Test Transaction",
      amount: 100,
      currency: "USD",
      date: Date.today,
      entryable: Transaction.create!
    )

    # Set raw_payload without the stale account
    @simplefin_item.update!(raw_payload: { accounts: [] })

    assert_difference [ "Account.count", "SimplefinAccount.count", "Entry.count" ], -1 do
      post complete_account_setup_simplefin_item_url(@simplefin_item), params: {
        stale_account_actions: {
          stale_sfa.id => { action: "delete" }
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "complete_account_setup moves transactions when move action selected" do
    # Create source (stale) account
    stale_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Bitcoin",
      account_id: "stale_btc",
      currency: "USD",
      current_balance: 0,
      account_type: "crypto"
    )
    stale_account = Account.create!(
      family: @family,
      name: "Bitcoin",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!
    )
    stale_sfa.update!(account: stale_account)
    stale_account.update!(simplefin_account_id: stale_sfa.id)

    # Create target account (active)
    target_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Cash",
      account_id: "active_cash",
      currency: "USD",
      current_balance: 1000,
      account_type: "depository"
    )
    target_account = Account.create!(
      family: @family,
      name: "Cash",
      balance: 1000,
      currency: "USD",
      accountable: Depository.create!(subtype: "checking")
    )
    target_sfa.update!(account: target_account)
    target_account.update!(simplefin_account_id: target_sfa.id)
    target_sfa.ensure_account_provider!

    # Add transactions to stale account
    entry1 = Entry.create!(
      account: stale_account,
      name: "P2P Transfer",
      amount: 300,
      currency: "USD",
      date: Date.today,
      entryable: Transaction.create!
    )
    entry2 = Entry.create!(
      account: stale_account,
      name: "Another Transfer",
      amount: 200,
      currency: "USD",
      date: Date.today - 1,
      entryable: Transaction.create!
    )

    # Set raw_payload with only the target account (stale account missing)
    @simplefin_item.update!(raw_payload: {
      accounts: [
        { id: "active_cash", name: "Cash", balance: 1000, currency: "USD" }
      ]
    })

    # Stale account should be deleted, target account should gain entries
    assert_difference "Account.count", -1 do
      assert_difference "SimplefinAccount.count", -1 do
        post complete_account_setup_simplefin_item_url(@simplefin_item), params: {
          stale_account_actions: {
            stale_sfa.id => { action: "move", target_account_id: target_account.id }
          }
        }
      end
    end

    assert_redirected_to accounts_path

    # Verify transactions were moved to target account
    entry1.reload
    entry2.reload
    assert_equal target_account.id, entry1.account_id
    assert_equal target_account.id, entry2.account_id
  end

  test "complete_account_setup skips stale account when skip action selected" do
    # Create a linked SimpleFIN account that will be stale
    stale_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Stale Account",
      account_id: "stale_skip",
      currency: "USD",
      current_balance: 0,
      account_type: "depository"
    )
    stale_account = Account.create!(
      family: @family,
      name: "Stale Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.create!(subtype: "checking")
    )
    stale_sfa.update!(account: stale_account)
    stale_account.update!(simplefin_account_id: stale_sfa.id)

    @simplefin_item.update!(raw_payload: { accounts: [] })

    assert_no_difference [ "Account.count", "SimplefinAccount.count" ] do
      post complete_account_setup_simplefin_item_url(@simplefin_item), params: {
        stale_account_actions: {
          stale_sfa.id => { action: "skip" }
        }
      }
    end

    assert_redirected_to accounts_path
    # Account and SimplefinAccount should still exist
    assert Account.exists?(stale_account.id)
    assert SimplefinAccount.exists?(stale_sfa.id)
  end
end
