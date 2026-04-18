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

  test "should update simplefin item access_url in place preserving account linkages" do
    @simplefin_item.update!(status: :requires_update)
    original_item_id = @simplefin_item.id

    token = Base64.strict_encode64("https://example.com/claim")

    # Create SimpleFIN accounts linked to Maybe accounts
    simplefin_account1 = @simplefin_item.simplefin_accounts.create!(
      name: "Test Checking",
      account_id: "sf_account_123",
      currency: "USD",
      current_balance: 1000,
      account_type: "depository"
    )
    simplefin_account2 = @simplefin_item.simplefin_accounts.create!(
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
      simplefin_account_id: simplefin_account1.id
    )
    maybe_account2 = Account.create!(
      family: @family,
      name: "Savings Account",
      balance: 5000,
      currency: "USD",
      accountable_type: "Depository",
      accountable: Depository.create!(subtype: "savings"),
      simplefin_account_id: simplefin_account2.id
    )

    # Update SimpleFIN accounts to reference the Maybe accounts
    simplefin_account1.update!(account: maybe_account1)
    simplefin_account2.update!(account: maybe_account2)

    # Mock only the external API calls
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with(token).returns("https://example.com/new_access")
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least_once

    # Perform the update - job updates access_url and enqueues sync
    perform_enqueued_jobs(only: SimplefinConnectionUpdateJob) do
      patch simplefin_item_url(@simplefin_item), params: {
        simplefin_item: { setup_token: token }
      }
    end

    assert_redirected_to accounts_path
    assert_equal "SimpleFIN connection updated.", flash[:notice]

    # Verify the same SimpleFIN item was updated (not a new one created)
    @simplefin_item.reload
    assert_equal original_item_id, @simplefin_item.id
    assert_equal "https://example.com/new_access", @simplefin_item.access_url
    assert_equal "good", @simplefin_item.status

    # Verify no duplicate SimpleFIN items were created
    assert_equal 1, @family.simplefin_items.count

    # Verify account linkages remain intact
    maybe_account1.reload
    maybe_account2.reload
    assert_equal simplefin_account1.id, maybe_account1.simplefin_account_id
    assert_equal simplefin_account2.id, maybe_account2.simplefin_account_id

    # Verify item is NOT scheduled for deletion (we updated it, not replaced it)
    assert_not @simplefin_item.scheduled_for_deletion?
  end

  test "should preserve account linkages when reconnecting even if accounts change" do
    @simplefin_item.update!(status: :requires_update)
    original_item_id = @simplefin_item.id

    token = Base64.strict_encode64("https://example.com/claim")

    # Create SimpleFIN account linked to Maybe account
    simplefin_account = @simplefin_item.simplefin_accounts.create!(
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
      simplefin_account_id: simplefin_account.id
    )
    simplefin_account.update!(account: maybe_account)

    # Mock only the external API calls
    mock_provider = mock()
    mock_provider.expects(:claim_access_url).with(token).returns("https://example.com/new_access")
    Provider::Simplefin.expects(:new).returns(mock_provider).at_least_once

    # Perform update - job updates access_url and enqueues sync
    perform_enqueued_jobs(only: SimplefinConnectionUpdateJob) do
      patch simplefin_item_url(@simplefin_item), params: {
        simplefin_item: { setup_token: token }
      }
    end

    assert_redirected_to accounts_path

    # Verify item was updated in place
    @simplefin_item.reload
    assert_equal original_item_id, @simplefin_item.id
    assert_equal "https://example.com/new_access", @simplefin_item.access_url

    # Verify account linkage remains intact (linkage preserved regardless of sync results)
    maybe_account.reload
    simplefin_account.reload
    assert_equal simplefin_account.id, maybe_account.simplefin_account_id
    assert_equal maybe_account, simplefin_account.current_account

    # Item is NOT scheduled for deletion (we updated it, not replaced it)
    assert_not @simplefin_item.scheduled_for_deletion?
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

  # Replacement detection prompt (surfaces on the SimpleFIN card when the
  # importer's ReplacementDetector has persisted suggestions on sync_stats).

  test "replacement prompt renders on accounts index when suggestions are persisted" do
    # Create the two sfas the detector would flag
    old_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Citi-3831", account_id: "sf_3831",
      currency: "USD", account_type: "credit", current_balance: 0,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        { "id" => "t", "transacted_at" => 90.days.ago.to_i, "posted" => 90.days.ago.to_i, "amount" => "-5" }
      ]
    )
    sure_account = Account.create!(
      family: @family,
      name: "Citi Double Cash Card-3831",
      balance: 0, currency: "USD",
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    AccountProvider.create!(account: sure_account, provider: old_sfa)

    new_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Citi-2879", account_id: "sf_2879",
      currency: "USD", account_type: "credit", current_balance: -1200,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        { "id" => "n", "transacted_at" => 2.days.ago.to_i, "posted" => 2.days.ago.to_i, "amount" => "-100" }
      ]
    )

    # Persist a suggestion on the latest sync
    sync = @simplefin_item.syncs.create!(status: :completed, sync_stats: {
      "replacement_suggestions" => [
        {
          "dormant_sfa_id" => old_sfa.id,
          "active_sfa_id" => new_sfa.id,
          "sure_account_id" => sure_account.id,
          "institution_name" => "Citibank",
          "dormant_account_name" => "Citi-3831",
          "active_account_name" => "Citi-2879",
          "confidence" => "high"
        }
      ]
    })
    sync.update_column(:created_at, Time.current)

    get accounts_url
    assert_response :success
    assert_match(/Citibank card may have been replaced/, response.body)
    assert_match(/Citi Double Cash Card-3831/, response.body)
    assert_match(/Relink to new card/, response.body)
  end

  test "replacement prompt is suppressed once the relink has been applied" do
    old_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Citi-3831", account_id: "sf_3831_applied",
      currency: "USD", account_type: "credit", current_balance: 0,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        { "id" => "t", "transacted_at" => 90.days.ago.to_i, "posted" => 90.days.ago.to_i, "amount" => "-5" }
      ]
    )
    sure_account = Account.create!(
      family: @family,
      name: "Citi Double Cash Card-3831 (applied)",
      balance: 0, currency: "USD",
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    new_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Citi-2879", account_id: "sf_2879_applied",
      currency: "USD", account_type: "credit", current_balance: -1200,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        { "id" => "n", "transacted_at" => 2.days.ago.to_i, "posted" => 2.days.ago.to_i, "amount" => "-100" }
      ]
    )
    # Simulate the post-relink state: new_sfa is now linked to the Sure account,
    # old_sfa is unlinked. sync_stats still carries the stale suggestion.
    AccountProvider.create!(account: sure_account, provider: new_sfa)
    sync = @simplefin_item.syncs.create!(status: :completed, sync_stats: {
      "replacement_suggestions" => [
        {
          "dormant_sfa_id" => old_sfa.id,
          "active_sfa_id" => new_sfa.id,
          "sure_account_id" => sure_account.id,
          "institution_name" => "Citibank",
          "dormant_account_name" => "Citi-3831",
          "active_account_name" => "Citi-2879",
          "confidence" => "high"
        }
      ]
    })
    sync.update_column(:created_at, Time.current)

    get accounts_url
    assert_response :success
    refute_match(/Citibank card may have been replaced/, response.body,
      "banner should disappear once the relink has landed on the new sfa")
  end

  test "dismissing a replacement suggestion hides the banner for that pair" do
    old_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Citi-3831", account_id: "sf_3831_dismiss",
      currency: "USD", account_type: "credit", current_balance: 0,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        { "id" => "t", "transacted_at" => 90.days.ago.to_i, "posted" => 90.days.ago.to_i, "amount" => "-5" }
      ]
    )
    sure_account = Account.create!(
      family: @family, name: "Citi Double Cash Card-3831 (dismiss)",
      balance: 0, currency: "USD",
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    AccountProvider.create!(account: sure_account, provider: old_sfa)
    new_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Citi-2879", account_id: "sf_2879_dismiss",
      currency: "USD", account_type: "credit", current_balance: -1200,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        { "id" => "n", "transacted_at" => 2.days.ago.to_i, "posted" => 2.days.ago.to_i, "amount" => "-100" }
      ]
    )
    sync = @simplefin_item.syncs.create!(status: :completed, sync_stats: {
      "replacement_suggestions" => [
        {
          "dormant_sfa_id" => old_sfa.id,
          "active_sfa_id" => new_sfa.id,
          "sure_account_id" => sure_account.id,
          "institution_name" => "Citibank",
          "confidence" => "high"
        }
      ]
    })
    sync.update_column(:created_at, Time.current)

    # Banner is present before dismissal
    get accounts_url
    assert_match(/Citibank card may have been replaced/, response.body)

    # Dismiss
    post dismiss_replacement_suggestion_simplefin_item_path(@simplefin_item), params: {
      dormant_sfa_id: old_sfa.id
    }
    sync.reload
    assert_includes Array(sync.sync_stats["dismissed_replacement_suggestions"]), old_sfa.id

    # Banner is gone after dismissal
    get accounts_url
    refute_match(/Citibank card may have been replaced/, response.body,
      "banner should not render for a dismissed dormant_sfa_id")
  end

  test "replacement prompt relink button successfully swaps AccountProvider" do
    old_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "Old", account_id: "o1", currency: "USD",
      account_type: "credit", current_balance: 0
    )
    new_sfa = @simplefin_item.simplefin_accounts.create!(
      name: "New", account_id: "n1", currency: "USD",
      account_type: "credit", current_balance: -500
    )
    sure_account = Account.create!(
      family: @family, name: "Citi", balance: 0, currency: "USD",
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    AccountProvider.create!(account: sure_account, provider: old_sfa)

    # The relink button posts to link_existing_account just like the modal does
    post link_existing_account_simplefin_items_path, params: {
      account_id: sure_account.id,
      simplefin_account_id: new_sfa.id
    }

    sure_account.reload
    sf_aps = sure_account.account_providers.where(provider_type: "SimplefinAccount")
    assert_equal 1, sf_aps.count
    assert_equal new_sfa.id, sf_aps.first.provider_id
  end

  # Same-provider relink tests (Bug #3 — allow SimpleFIN-to-SimpleFIN swap without unlink dance)

  test "link_existing_account allows relink when account is already SimpleFIN-linked via AccountProvider" do
    # @account currently linked to sfa_old (fraud-replaced card). User picks sfa_new.
    account = Account.create!(
      family: @family,
      name: "Citi Double Cash",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    sfa_old = @simplefin_item.simplefin_accounts.create!(
      name: "Citi Card-OLD",
      account_id: "sf_citi_old",
      currency: "USD",
      account_type: "credit",
      current_balance: 0
    )
    sfa_new = @simplefin_item.simplefin_accounts.create!(
      name: "Citi Card-NEW",
      account_id: "sf_citi_new",
      currency: "USD",
      account_type: "credit",
      current_balance: -100
    )
    AccountProvider.create!(account: account, provider: sfa_old)

    post link_existing_account_simplefin_items_path, params: {
      account_id: account.id,
      simplefin_account_id: sfa_new.id
    }

    assert_response :see_other

    # The SimpleFIN link should now point at sfa_new
    account.reload
    sf_providers = account.account_providers.where(provider_type: "SimplefinAccount")
    assert_equal 1, sf_providers.count, "should have exactly one SimpleFIN link after relink"
    assert_equal sfa_new.id, sf_providers.first.provider_id

    # Old AccountProvider for sfa_old on this account is detached
    refute AccountProvider.exists?(account_id: account.id, provider: sfa_old),
      "old SimpleFIN AccountProvider for this account should be detached"
  end

  test "link_existing_account allows relink when account has only legacy simplefin_account_id FK" do
    account = Account.create!(
      family: @family,
      name: "Citi Double Cash",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    sfa_old = @simplefin_item.simplefin_accounts.create!(
      name: "Citi Card-OLD",
      account_id: "sf_citi_old2",
      currency: "USD",
      account_type: "credit",
      current_balance: 0
    )
    sfa_new = @simplefin_item.simplefin_accounts.create!(
      name: "Citi Card-NEW",
      account_id: "sf_citi_new2",
      currency: "USD",
      account_type: "credit",
      current_balance: -100
    )
    account.update!(simplefin_account_id: sfa_old.id)

    post link_existing_account_simplefin_items_path, params: {
      account_id: account.id,
      simplefin_account_id: sfa_new.id
    }

    assert_response :see_other
    account.reload
    assert_nil account.simplefin_account_id, "legacy SimpleFIN FK should be cleared"
    assert_equal sfa_new.id,
      account.account_providers.where(provider_type: "SimplefinAccount").first&.provider_id
  end

  test "link_existing_account rejects when account is linked to a foreign provider (Plaid)" do
    account = Account.create!(
      family: @family,
      name: "Plaid-Linked",
      balance: 0,
      currency: "USD",
      accountable: Depository.create!(subtype: "checking")
    )
    plaid_item = PlaidItem.create!(family: @family, name: "Plaid Conn", access_token: "t", plaid_id: "p")
    plaid_acct = PlaidAccount.create!(
      plaid_item: plaid_item,
      plaid_id: "p_acct_1",
      name: "Plaid A",
      plaid_type: "depository",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: account, provider: plaid_acct)

    sfa = @simplefin_item.simplefin_accounts.create!(
      name: "SF-Target",
      account_id: "sf_target_1",
      currency: "USD",
      account_type: "depository",
      current_balance: 100
    )

    post link_existing_account_simplefin_items_path, params: {
      account_id: account.id,
      simplefin_account_id: sfa.id
    }

    # Should NOT have attached the SimpleFIN provider
    account.reload
    assert_empty account.account_providers.where(provider_type: "SimplefinAccount")
    # Plaid link should remain intact
    assert account.account_providers.where(provider_type: "PlaidAccount").exists?
  end

  # Activity badge tests (helps users distinguish live vs replaced/closed cards during setup)

  test "setup_accounts renders recent-transactions badge for active sfa" do
    @simplefin_item.simplefin_accounts.create!(
      name: "Active Card",
      account_id: "active_card_1",
      currency: "USD",
      account_type: "credit",
      current_balance: -123.45,
      raw_transactions_payload: [
        { "id" => "t1", "transacted_at" => 3.days.ago.to_i, "posted" => 3.days.ago.to_i, "amount" => "-10" },
        { "id" => "t2", "transacted_at" => 10.days.ago.to_i, "posted" => 10.days.ago.to_i, "amount" => "-20" }
      ]
    )

    get setup_accounts_simplefin_item_url(@simplefin_item)
    assert_response :success
    assert_match(/2 transactions.*3 days ago/, response.body,
      "expected active sfa to show recent transaction count and last activity")
  end

  test "setup_accounts renders 'likely closed' warning for dormant+zero-balance sfa" do
    @simplefin_item.simplefin_accounts.create!(
      name: "Dead Card",
      account_id: "dead_card_1",
      currency: "USD",
      account_type: "credit",
      current_balance: 0,
      raw_transactions_payload: [
        { "id" => "old", "transacted_at" => 120.days.ago.to_i, "posted" => 120.days.ago.to_i, "amount" => "-5" }
      ]
    )

    get setup_accounts_simplefin_item_url(@simplefin_item)
    assert_response :success
    assert_match(/closed or replaced card/, response.body,
      "expected dormant+zero-balance sfa to show closed/replaced warning")
  end

  test "setup_accounts renders 'no transactions imported' for empty sfa" do
    @simplefin_item.simplefin_accounts.create!(
      name: "Brand New Card",
      account_id: "fresh_card_1",
      currency: "USD",
      account_type: "credit",
      current_balance: 0,
      raw_transactions_payload: []
    )

    get setup_accounts_simplefin_item_url(@simplefin_item)
    assert_response :success
    assert_match(/No transactions imported yet/, response.body)
  end

  test "setup_accounts renders 'dormant but has balance' as plain text not warning" do
    # Legitimate dormant case: HSA/savings account with real balance but no recent activity.
    # Should NOT be flagged as likely-closed because the balance is non-trivial.
    @simplefin_item.simplefin_accounts.create!(
      name: "Dormant HSA",
      account_id: "dormant_hsa_1",
      currency: "USD",
      account_type: "investment",
      current_balance: 5432.10,
      raw_transactions_payload: [
        { "id" => "old", "transacted_at" => 120.days.ago.to_i, "posted" => 120.days.ago.to_i, "amount" => "100" }
      ]
    )

    get setup_accounts_simplefin_item_url(@simplefin_item)
    assert_response :success
    assert_match(/No activity in 120 days/, response.body)
    refute_match(/closed or replaced card/, response.body,
      "dormant accounts with real balances should not be marked as closed")
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
