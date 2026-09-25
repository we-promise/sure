require "test_helper"
require "ostruct"

class PlaidItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "new redirects with friendly alert when Plaid rejects link_token request for unauthorized products" do
    # Reproduces issue #1792: the Plaid client account isn't enabled for the
    # requested products, so Plaid returns an actionable error message. We
    # should surface that message instead of letting the modal frame render
    # blank.
    plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).with(:us).returns(plaid_provider)

    error_body = {
      "error_code" => "INVALID_PRODUCT",
      "error_message" => "Your account is not enabled for the following products: [\"investments\" \"liabilities\" \"transactions\"]. To request access, visit https://dashboard.plaid.com/overview/request-products or contact Sales or your Account Manager."
    }.to_json
    plaid_provider.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 400, response_body: error_body)
    )

    get new_plaid_item_url(accountable_type: "Investment")

    assert_redirected_to accounts_path
    assert_match(/not enabled for the following products/, flash[:alert])
  end

  test "new redirects with generic alert when Plaid raises an unclassified error" do
    plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).with(:us).returns(plaid_provider)

    plaid_provider.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 500, response_body: { "error_code" => "INTERNAL_SERVER_ERROR" }.to_json)
    )

    get new_plaid_item_url

    assert_redirected_to accounts_path
    assert_equal I18n.t("plaid_items.errors.link_token_generic"), flash[:alert]
  end

  test "edit redirects with friendly alert when Plaid rejects update link_token request" do
    plaid_item = plaid_items(:one)
    error_body = {
      "error_code" => "INVALID_PRODUCT",
      "error_message" => "Your account is not enabled for the following products: [\"transactions\"]."
    }.to_json
    PlaidItem.any_instance.expects(:get_update_link_token).raises(
      Plaid::ApiError.new(code: 400, response_body: error_body)
    )

    get edit_plaid_item_url(plaid_item)

    assert_redirected_to accounts_path
    assert_match(/not enabled for the following products/, flash[:alert])
  end

  test "edit enables account selection when adding accounts" do
    plaid_item = plaid_items(:one)
    PlaidItem.any_instance.expects(:get_update_link_token).with(
      webhooks_url: webhooks_plaid_url,
      redirect_url: accounts_url,
      account_selection_enabled: true
    ).returns("link-token")

    get edit_plaid_item_url(plaid_item, add_accounts: true)

    assert_response :success
  end

  test "edit does not enable account selection for EU items" do
    plaid_item = plaid_items(:one)
    plaid_item.update!(plaid_region: :eu)
    PlaidItem.any_instance.expects(:get_update_link_token).with(
      webhooks_url: webhooks_plaid_eu_url,
      redirect_url: accounts_url,
      account_selection_enabled: false
    ).returns("link-token")

    get edit_plaid_item_url(plaid_item, add_accounts: true)

    assert_response :success
  end

  test "create" do
    @plaid_provider = mock
    Provider::Registry.expects(:plaid_provider_for_region).with("us").returns(@plaid_provider)

    public_token = "public-sandbox-1234"

    @plaid_provider.expects(:exchange_public_token).with(public_token).returns(
      OpenStruct.new(access_token: "access-sandbox-1234", item_id: "item-sandbox-1234")
    )

    assert_difference "PlaidItem.count", 1 do
      post plaid_items_url, params: {
        plaid_item: {
          public_token: public_token,
          region: "us",
          metadata: { institution: { name: "Plaid Item Name" } }
        }
      }
    end

    assert_equal "Account linked successfully.  Please wait for accounts to sync.", flash[:notice]
    assert_redirected_to accounts_path
  end

  test "create persists the selected Plaid profile" do
    @plaid_provider = mock
    Provider::Registry.expects(:plaid_provider_for_region).with("us", profile: "secondary").returns(@plaid_provider)

    @plaid_provider.expects(:exchange_public_token).with("public-secondary").returns(
      OpenStruct.new(access_token: "access-secondary", item_id: "item-secondary")
    )

    with_env_overrides(
      PLAID_PROFILE_SECONDARY_CLIENT_ID: "secondary-client",
      PLAID_PROFILE_SECONDARY_SECRET: "secondary-secret",
      PLAID_PROFILE_SECONDARY_ENV: "sandbox"
    ) do
      assert_difference "PlaidItem.count", 1 do
        post plaid_items_url, params: {
          plaid_item: {
            public_token: "public-secondary",
            region: "us",
            profile: "secondary",
            metadata: { institution: { name: "Secondary Bank" } }
          }
        }
      end
    end

    assert_equal "secondary", PlaidItem.find_by(plaid_id: "item-secondary").plaid_profile
  end

  test "destroy" do
    delete plaid_item_url(plaid_items(:one))

    assert_equal "Accounts scheduled for deletion.", flash[:notice]
    assert_enqueued_with job: DestroyJob
    assert_redirected_to accounts_path
  end

  test "sync" do
    plaid_item = plaid_items(:one)
    PlaidItem.any_instance.expects(:sync_later_with_provider_refresh).once

    post sync_plaid_item_url(plaid_item)

    assert_redirected_to accounts_path
  end

  test "select_existing_account redirects when no available plaid accounts" do
    account = accounts(:depository)

    get select_existing_account_plaid_items_url(account_id: account.id, region: "us")
    assert_redirected_to account_path(account)
    assert_equal "No available Plaid accounts to link. Please connect a new Plaid account first.", flash[:alert]
  end

  test "link_existing_account links plaid account to existing account" do
    account = accounts(:depository)

    # Create a new unlinked plaid_account for testing
    plaid_account = PlaidAccount.create!(
      plaid_item: plaid_items(:one),
      name: "Test Plaid Account",
      plaid_id: "test_acc_123",
      plaid_type: "depository",
      plaid_subtype: "checking",
      currency: "USD",
      current_balance: 1000,
      available_balance: 1000
    )

    assert_not account.linked?
    assert_nil plaid_account.account
    assert_nil plaid_account.account_provider

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_plaid_items_url, params: {
        account_id: account.id,
        plaid_account_id: plaid_account.id
      }
    end

    account.reload
    assert account.linked?, "Account should be linked after creating AccountProvider"
    assert_equal 1, account.account_providers.count
    assert_redirected_to accounts_path
    assert_equal "Account successfully linked to Plaid", flash[:notice]
  end

  # --- member-owned connections (issue #3579) ------------------------------
  #
  # Plaid declares `credential_scope :per_connection`, so a household member
  # may connect their own bank. Admin behaviour is unchanged: an admin still
  # sees and manages every connection in the family.

  test "a member may open the Plaid link flow" do
    sign_in users(:family_member)
    plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).with(:us).returns(plaid_provider)
    plaid_provider.expects(:get_link_token).returns(OpenStruct.new(link_token: "link-token-member"))

    get new_plaid_item_url

    assert_response :success
  end

  test "a guest may not open the Plaid link flow" do
    guest = users(:family_member)
    guest.update!(role: :guest)
    sign_in guest

    get new_plaid_item_url

    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_connector_owner"), flash[:alert]
  end

  test "a member who creates an item becomes its owner" do
    member = users(:family_member)
    sign_in member

    plaid_provider = mock
    Provider::Registry.expects(:plaid_provider_for_region).with("us").returns(plaid_provider)
    plaid_provider.expects(:exchange_public_token).returns(
      OpenStruct.new(access_token: "access-sandbox-member", item_id: "item-sandbox-member")
    )

    post plaid_items_url, params: {
      plaid_item: {
        public_token: "public-sandbox-member",
        region: "us",
        metadata: { institution: { name: "Member Bank" } }
      }
    }

    assert_equal member, PlaidItem.order(:created_at).last.owner
  end

  test "a member may destroy a connection they own" do
    member = users(:family_member)
    plaid_items(:one).update!(owner: member)
    sign_in member

    delete plaid_item_url(plaid_items(:one))

    assert_enqueued_with job: DestroyJob
    assert_redirected_to accounts_path
  end

  test "a member may not destroy a connection owned by someone else" do
    plaid_items(:one).update!(owner: users(:family_admin))
    sign_in users(:family_member)

    assert_no_enqueued_jobs only: DestroyJob do
      delete plaid_item_url(plaid_items(:one))
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_connector_owner"), flash[:alert]
  end

  test "a member may not sync a connection owned by someone else" do
    plaid_items(:one).update!(owner: users(:family_admin))
    sign_in users(:family_member)
    PlaidItem.any_instance.expects(:sync_later_with_provider_refresh).never

    post sync_plaid_item_url(plaid_items(:one))

    assert_redirected_to accounts_path
  end

  test "an admin may still manage a connection a member owns" do
    plaid_items(:one).update!(owner: users(:family_member))
    sign_in users(:family_admin)
    PlaidItem.any_instance.expects(:sync_later_with_provider_refresh).once

    post sync_plaid_item_url(plaid_items(:one))

    assert_redirected_to accounts_path
  end

  test "a member may not link an account to a connection someone else owns" do
    plaid_items(:one).update!(owner: users(:family_admin))
    member = users(:family_member)
    account = Account.create!(
      family: families(:dylan_family), owner: member, name: "Member Checking",
      balance: 100, currency: "USD", accountable: Depository.new
    )
    plaid_account = PlaidAccount.create!(
      plaid_item: plaid_items(:one), name: "Not Theirs", plaid_id: "acct_not_theirs",
      plaid_type: "depository", plaid_subtype: "checking", currency: "USD",
      current_balance: 100, available_balance: 100
    )
    sign_in member

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_plaid_items_url, params: {
        account_id: account.id, plaid_account_id: plaid_account.id
      }
    end

    assert_redirected_to account_path(account)
  end

  test "a member may not attach their own connection to an account they cannot write" do
    member = users(:family_member)
    plaid_items(:one).update!(owner: member)
    other_account = Account.create!(
      family: families(:dylan_family), owner: users(:family_admin),
      name: "Admin Only Checking", balance: 100, currency: "USD", accountable: Depository.new
    )
    plaid_account = PlaidAccount.create!(
      plaid_item: plaid_items(:one), name: "Theirs", plaid_id: "acct_theirs",
      plaid_type: "depository", plaid_subtype: "checking", currency: "USD",
      current_balance: 100, available_balance: 100
    )
    sign_in member

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_plaid_items_url, params: {
        account_id: other_account.id, plaid_account_id: plaid_account.id
      }
    end
  end

  test "select_existing_account offers a member only the connections they own" do
    member = users(:family_member)
    plaid_items(:one).update!(owner: users(:family_admin))
    account = Account.create!(
      family: families(:dylan_family), owner: member, name: "Member Savings",
      balance: 100, currency: "USD", accountable: Depository.new
    )
    PlaidAccount.create!(
      plaid_item: plaid_items(:one), name: "Admin Feed", plaid_id: "acct_admin_feed",
      plaid_type: "depository", plaid_subtype: "checking", currency: "USD",
      current_balance: 100, available_balance: 100
    )
    sign_in member

    get select_existing_account_plaid_items_url(account_id: account.id, region: "us")

    assert_redirected_to account_path(account)
    assert_equal "No available Plaid accounts to link. Please connect a new Plaid account first.", flash[:alert]
  end
end
