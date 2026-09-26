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
          metadata: { institution: { name: "Plaid Item Name", institution_id: "ins_mock" } }
        }
      }
    end

    # Link's onSuccess metadata nests the institution, unlike the flat onEvent
    # metadata the Stimulus controller reads. Persisting the id here closes the
    # window where a just-linked connection is invisible to the duplicate check,
    # which would otherwise last until the first sync completes.
    assert_equal "ins_mock", PlaidItem.order(:created_at).last.institution_id
    assert_equal "Account linked successfully.  Please wait for accounts to sync.", flash[:notice]
    assert_redirected_to accounts_path
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

  # --- Duplicate-connection warning -------------------------------------------
  #
  # The SELECT_INSTITUTION interception itself lives in plaid_controller.js and has
  # no automated coverage: the repo has no Stimulus test harness, and driving Plaid's
  # own iframe is out of reach for a system test. Everything the JavaScript *decides
  # on* is computed here, which is why these tests carry the weight.

  test "new exposes the institutions this family already has connected" do
    stub_link_token
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    get new_plaid_item_url(region: "us")

    assert_includes connected_institution_ids, "ins_example"
  end

  test "new omits connections scheduled for deletion" do
    stub_link_token
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    item.update!(scheduled_for_deletion: true)

    get new_plaid_item_url(region: "us")

    assert_empty connected_institution_ids
  end

  test "new omits connections from the other region" do
    stub_link_token
    create_plaid_item(name: "EU Bank", institution_id: "ins_eu", region: :eu, owner: users(:family_admin))

    get new_plaid_item_url(region: "us")

    assert_empty connected_institution_ids
  end

  # Without a normalized region the query would run against a nil plaid_region and
  # match nothing, silently disabling the warning on the most common entry path --
  # the provider links omit `region` only when the caller does, but `new` itself has
  # always defaulted to :us, and the partial must agree with it.
  test "new defaults to the us region when none is given" do
    stub_link_token
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    get new_plaid_item_url

    assert_includes connected_institution_ids, "ins_example"
  end

  test "new omits the institution the user chose to connect again" do
    stub_link_token
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    get new_plaid_item_url(region: "us", allow_institution: "ins_example")

    assert_empty connected_institution_ids
  end

  # Signed in as a family with no Plaid items at all -- dylan_family carries the
  # `plaid_items(:one)` fixture, which has no institution_id and so legitimately shows
  # up in the name-fallback list.
  test "new exposes an empty list when the family has no connections" do
    stub_link_token
    sign_in users(:empty)

    get new_plaid_item_url(region: "us")

    assert_empty connected_institution_ids
    assert_empty connected_institution_names
  end

  # An item whose first sync never landed has no institution_id, and a broken
  # connection is exactly what a user tries to re-link. Fall back to the stored name.
  test "new falls back to the institution name when no institution_id was stored" do
    stub_link_token
    create_plaid_item(name: "Chase", institution_id: nil, owner: users(:family_admin))

    get new_plaid_item_url(region: "us")

    assert_empty connected_institution_ids
    assert_includes connected_institution_names, "chase"
  end

  test "new hides another member's connection from a member" do
    stub_link_token
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    sign_in users(:family_member)

    get new_plaid_item_url(region: "us")

    assert_empty connected_institution_ids
  end

  # Admins keep family-wide oversight, and the harm is family-wide too: the family
  # shares one Plaid client and one Item allowance, so a member's existing connection
  # really does mean an admin's new one spends a second slot.
  test "new shows a member's connection to an admin" do
    stub_link_token
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_member))

    get new_plaid_item_url(region: "us")

    assert_includes connected_institution_ids, "ins_example"
  end

  test "duplicate_warning lists the existing connection with its accounts and masks" do
    create_plaid_item(
      name: "Example Bank",
      institution_id: "ins_example",
      owner: users(:family_admin),
      accounts: [
        { name: "Example Checking", mask: "4321" },
        { name: "Example Savings", mask: "8765" }
      ]
    )

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_response :success
    assert_match "Example Checking", response.body
    assert_match "4321", response.body
    assert_match "Example Savings", response.body
    assert_match "8765", response.body
  end

  # A family that already hit this bug holds several connections for one institution,
  # and is exactly who the warning matters most to. Every match is listed, and the
  # title counts them rather than reading as though there were one.
  test "duplicate_warning lists every connection for the institution" do
    first = create_plaid_item(name: "Example Bank", institution_id: "ins_example",
                              owner: users(:family_admin), accounts: [ { name: "First Checking", mask: "4321" } ])
    second = create_plaid_item(name: "Example Bank (2nd login)", institution_id: "ins_example",
                               owner: users(:family_admin), accounts: [ { name: "Second Checking", mask: "5150" } ])

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_response :success
    assert_match "First Checking", response.body
    assert_match "Second Checking", response.body
    assert_select "a[href=?]", edit_plaid_item_path(first, add_accounts: true)
    assert_select "a[href=?]", edit_plaid_item_path(second, add_accounts: true)
    assert_select "h2", text: I18n.t("plaid_items.duplicate_warning.title", count: 2)
  end

  # The warning has to argue both sides. A second login covering different accounts
  # duplicates nothing, so the dialog says so rather than presenting every match as a
  # mistake -- a warning that is false for the people the override exists to serve
  # costs more than one that is merely unnecessary.
  test "duplicate_warning states when a new connection is legitimate" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_response :success
    assert_select "p", text: /different login with different accounts/
  end

  # owner_id is nullable and `owned_by?` is false for a null owner, so the attribution
  # line would otherwise render for connections predating per-user ownership (#3613).
  # An admin sees every family connection, so this is reachable rather than theoretical.
  test "duplicate_warning omits attribution for a connection with no owner" do
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    item.update_column(:owner_id, nil)

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_response :success
    # assert_no_match on the body rather than assert_select: the selector strips the
    # element's text, so a pattern ending in the interpolation's leading space silently
    # matches nothing and the test passes whether or not the line renders.
    assert_no_match(/Connected by/, response.body)
  end

  test "duplicate_warning titles a single match in the singular" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_select "h2", text: I18n.t("plaid_items.duplicate_warning.title", count: 1)
  end

  test "duplicate_warning offers the add-accounts route for a us connection" do
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_select "a[href=?]", edit_plaid_item_path(item, add_accounts: true)
  end

  # Update mode only accepts account selection for US items, so the link would be
  # inert for an EU connection.
  test "duplicate_warning omits the add-accounts route for an eu connection" do
    item = create_plaid_item(name: "EU Bank", institution_id: "ins_eu", region: :eu, owner: users(:family_admin))

    get duplicate_warning_plaid_items_url(region: "eu", institution_id: "ins_eu")

    assert_response :success
    assert_select "a[href=?]", edit_plaid_item_path(item, add_accounts: true), count: 0
    # assert_select rather than assert_match: the copy contains an apostrophe, which
    # is HTML-escaped in the body but decoded by the selector's text matcher.
    assert_select "p", text: /support adding accounts to an existing/
  end

  # The "or" separator implies a choice. When nothing above it is actionable it
  # dangles over a lone button, so it renders only alongside a connection action.
  test "duplicate_warning omits the or separator when no connection is actionable" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    PlaidItem.any_instance.stubs(:manageable_by?).returns(false)

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_response :success
    assert_select "p", text: I18n.t("plaid_items.duplicate_warning.or"), count: 0
    assert_select "a[href=?]", new_plaid_item_path(region: "us", allow_institution: "ins_example")
  end

  test "duplicate_warning always offers a way to connect anyway" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example", accountable_type: "Depository")

    assert_select "a[href=?]", new_plaid_item_path(
      region: "us", accountable_type: "Depository", allow_institution: "ins_example"
    )
  end

  test "duplicate_warning matches on name when the connection has no institution_id" do
    create_plaid_item(name: "Chase", institution_id: nil, owner: users(:family_admin))

    get duplicate_warning_plaid_items_url(region: "us", institution_name: "chase")

    assert_response :success
    assert_match "Chase", response.body
  end

  # A confirmed institution_id mismatch plus a shared display name is a false
  # positive, not a match -- the fallback is only for rows with no id at all.
  test "duplicate_warning does not match on name when the connection has an institution_id" do
    create_plaid_item(name: "Chase", institution_id: "ins_chase", owner: users(:family_admin))

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_other", institution_name: "chase")

    assert_redirected_to new_plaid_item_path(region: :us, allow_institution: "ins_other", allow_institution_name: "chase")
  end

  # Link is already closed by the time this renders, so an empty dialog would strand
  # the user with no way forward. Start a fresh Link session instead.
  test "duplicate_warning redirects into a fresh link session when nothing matches" do
    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_unknown")

    assert_redirected_to new_plaid_item_path(region: :us, allow_institution: "ins_unknown")
  end

  test "duplicate_warning does not match another family's connection" do
    create_plaid_item(family: families(:empty), name: "Example Bank", institution_id: "ins_example", owner: users(:empty))

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_redirected_to new_plaid_item_path(region: :us, allow_institution: "ins_example")
  end

  test "duplicate_warning hides another member's connection from a member" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    sign_in users(:family_member)

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_redirected_to new_plaid_item_path(region: :us, allow_institution: "ins_example")
  end

  test "duplicate_warning denies a guest" do
    sign_in users(:intro_user)

    get duplicate_warning_plaid_items_url(region: "us", institution_id: "ins_example")

    assert_redirected_to accounts_path
  end

  private
    def stub_link_token(region: :us)
      provider = mock
      Provider::Registry.stubs(:plaid_provider_for_region).with(region).returns(provider)
      provider.stubs(:get_link_token).returns(OpenStruct.new(link_token: "test-link-token"))
      provider
    end

    # Built inline rather than as fixtures so the surrounding suites keep the Plaid
    # item counts they were written against.
    def create_plaid_item(family: families(:dylan_family), name:, institution_id: nil, region: :us, owner: nil, accounts: [])
      item = family.plaid_items.create!(
        name: name,
        plaid_id: "item_#{SecureRandom.hex(6)}",
        access_token: "access-#{SecureRandom.hex(6)}",
        plaid_region: region,
        institution_id: institution_id,
        owner: owner
      )

      accounts.each do |attrs|
        item.plaid_accounts.create!(
          {
            plaid_id: "acct_#{SecureRandom.hex(6)}",
            currency: "USD",
            plaid_type: "depository",
            plaid_subtype: "checking",
            current_balance: 100,
            available_balance: 100
          }.merge(attrs)
        )
      end

      item
    end

    def plaid_link_element
      css_select("[data-controller='plaid']").first
    end

    def connected_institution_ids
      JSON.parse(plaid_link_element["data-plaid-connected-institution-ids-value"])
    end

    def connected_institution_names
      JSON.parse(plaid_link_element["data-plaid-connected-institution-names-value"])
    end
end
