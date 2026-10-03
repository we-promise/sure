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

    # Link's onSuccess metadata nests the institution. Persisting the id here closes
    # the window where a just-linked connection is invisible to the duplicate check,
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

  # --- Duplicate-connection gate ---------------------------------------------
  #
  # Plaid Link on the web holds back every event except OPEN and LAYER_* until the
  # end of the flow and delivers them alongside onSuccess, so nothing in the browser
  # runs early enough to stop a user from authenticating at a bank they already
  # connected. What is left is this point, before the public token is exchanged:
  # an access token is what counts against a Trial plan's Item limit, and Plaid's
  # duplicate-Items guidance is not to exchange a duplicate at all. The JavaScript
  # only forwards onSuccess and renders whatever comes back, so these tests carry
  # the weight.

  HELD_TOKEN = "public-sandbox-held"

  test "create holds the exchange when the institution is already connected" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    stub_plaid_provider.expects(:exchange_public_token).never

    assert_no_difference "PlaidItem.count" do
      post_link(institution_id: "ins_example", institution_name: "Example Bank")
    end

    assert_duplicate_warning
  end

  test "create exchanges the held token once the user confirms" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    assert_exchanges do
      post_link(institution_id: "ins_example", institution_name: "Example Bank", confirm: true)
    end
  end

  # A stream rather than a plain redirect, because the JavaScript's fetch follows a
  # redirect by itself -- and that discarded GET consumed the flash, so the success
  # notice never reached the page the user actually landed on.
  test "create redirects by stream with the success notice when nothing matches" do
    assert_exchanges do
      post_link(institution_id: "ins_new", institution_name: "New Bank")
    end

    assert_equal I18n.t("plaid_items.create.success"), flash[:notice]
  end

  test "create lists the existing connection with its accounts and masks" do
    create_plaid_item(
      name: "Example Bank",
      institution_id: "ins_example",
      owner: users(:family_admin),
      accounts: [
        { name: "Example Checking", mask: "4321" },
        { name: "Example Savings", mask: "8765" }
      ]
    )

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning
    assert_match "Example Checking", response.body
    assert_match "4321", response.body
    assert_match "Example Savings", response.body
    assert_match "8765", response.body
  end

  # A family that already hit this bug holds several connections for one institution,
  # and is exactly who the warning matters most to. Every match is listed, and the
  # title counts them rather than reading as though there were one.
  test "create lists every connection for the institution" do
    first = create_plaid_item(name: "Example Bank", institution_id: "ins_example",
                              owner: users(:family_admin), accounts: [ { name: "First Checking", mask: "4321" } ])
    second = create_plaid_item(name: "Example Bank (2nd login)", institution_id: "ins_example",
                               owner: users(:family_admin), accounts: [ { name: "Second Checking", mask: "5150" } ])

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "a[href=?]", edit_plaid_item_path(first, add_accounts: true)
      assert_select "a[href=?]", edit_plaid_item_path(second, add_accounts: true)
      assert_select "h2", text: I18n.t("plaid_items.duplicate_warning.title", count: 2)
    end
    assert_match "First Checking", response.body
    assert_match "Second Checking", response.body
  end

  test "create titles a single match in the singular" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "h2", text: I18n.t("plaid_items.duplicate_warning.title", count: 1)
    end
  end

  # Link reports the new connection's accounts -- whichever the user selected, or all of
  # them when Plaid preselects or skips account selection -- so the warning says whether
  # they are already connected instead of asking which login the user signed in with.
  test "create says when every account in the new connection is already connected" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin),
                      accounts: [ { name: "Example Checking", mask: "4321" }, { name: "Example Savings", mask: "8765" } ])

    post_link(institution_id: "ins_example", institution_name: "Example Bank",
              accounts: [ { name: "Example Checking", mask: "4321" }, { name: "Example Savings", mask: "8765" } ])

    assert_duplicate_warning do
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.overlap.all_connected", count: 2)
    end
  end

  # When every account already matches, adding the connection can only duplicate them
  # and spend a Plaid connection, so there is no way to add it. Every reason left to
  # re-link -- more accounts, or a connection that stopped working -- goes through
  # update mode on the existing connection instead. Without the form, the held token
  # never reaches the page at all.
  test "create offers no way to add the connection when every account is already connected" do
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin),
                             accounts: [ { name: "Example Checking", mask: "4321" } ])

    post_link(institution_id: "ins_example", institution_name: "Example Bank",
              accounts: [ { name: "Example Checking", mask: "4321" } ])

    assert_duplicate_warning do
      assert_select "form[action=?]", plaid_items_path, count: 0
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.or"), count: 0
      assert_select "button", text: I18n.t("plaid_items.duplicate_warning.keep_existing")
      assert_select "a[href=?]", edit_plaid_item_path(item, add_accounts: true)
    end
    assert_no_match HELD_TOKEN, response.body
  end

  # Without masks there is only a name to compare, and a different login's generic
  # "Brokerage" account can share it. So the warning stays general and keeps the
  # override instead of declaring the accounts already connected.
  test "create keeps the override when the reported accounts have no masks" do
    create_plaid_item(name: "Example Brokerage", institution_id: "ins_example", owner: users(:family_admin),
                      accounts: [ { name: "Brokerage", mask: nil } ])

    post_link(institution_id: "ins_example", institution_name: "Example Brokerage",
              accounts: [ { name: "Brokerage", mask: "" } ])

    assert_duplicate_warning do
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.overlap.unknown")
      assert_select "form[action=?]", plaid_items_path
    end
  end

  test "create lists the new connection's accounts that are not connected yet" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin),
                      accounts: [ { name: "Example Checking", mask: "4321" } ])

    post_link(institution_id: "ins_example", institution_name: "Example Bank",
              accounts: [ { name: "Example Checking", mask: "4321" }, { name: "Example HSA", mask: "7777" } ])

    assert_duplicate_warning do
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.overlap.some_connected.unconnected", count: 1)
      assert_select "dl > div", text: /Example HSA\s*\*{4}7777/
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.overlap.some_connected.connected", count: 1)
      assert_select "form[action=?] button", plaid_items_path, text: I18n.t("plaid_items.duplicate_warning.add_new_connection")
    end
  end

  # The warning argues both sides. A second login with different accounts duplicates
  # nothing, and saying so matters more than the warning itself: a warning that is
  # false for the people the override serves costs more than an unneeded one. It
  # still appears, though, so a renamed account can't carry a real duplicate past it.
  test "create says when none of the new connection's accounts are connected" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin),
                      accounts: [ { name: "Example Checking", mask: "4321" } ])

    post_link(institution_id: "ins_example", institution_name: "Example Bank",
              accounts: [ { name: "Business Checking", mask: "9999" } ])

    assert_duplicate_warning do
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.overlap.none_connected")
    end
  end

  test "create falls back to general copy when Link reports no accounts" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin),
                      accounts: [ { name: "Example Checking", mask: "4321" } ])

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.overlap.unknown")
    end
  end

  # owner_id is nullable and `owned_by?` is false for a null owner, so the attribution
  # line would otherwise render for connections predating per-user ownership (#3613).
  # An admin sees every family connection, so this is reachable rather than theoretical.
  test "create omits attribution for a connection with no owner" do
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    item.update_column(:owner_id, nil)

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning
    # assert_no_match on the body rather than assert_select: the selector strips the
    # element's text, so a pattern ending in the interpolation's leading space silently
    # matches nothing and the test passes whether or not the line renders.
    assert_no_match(/Connected by/, response.body)
  end

  # Whether to duplicate a connection or keep the existing one is not a choice a
  # stray click should make -- the dialog opens as Link closes, wherever Link left
  # the pointer.
  test "create does not let a stray click dismiss the warning" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      # Lowercased: HTML parsers downcase attribute names, so the selector cannot use
      # the `DS` casing that appears in the source.
      assert_select "dialog[data-ds--dialog-disable-click-outside-value=?]", "true"
    end
  end

  # The warning carries a live public token. Turbo would otherwise keep it in the page
  # snapshot it caches on navigation, and Back would restore a dialog able to spend it.
  test "create keeps the warning out of Turbo's page cache" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "dialog[data-turbo-temporary]"
    end
  end

  # Plaid only changes an existing connection through an update-mode session, so the
  # route to more accounts runs through the existing connection, not a new one.
  test "create offers the add-accounts route for a us connection" do
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "a[href=?]", edit_plaid_item_path(item, add_accounts: true)
    end
  end

  # GET edit mints a Plaid update-mode link token as a side effect, so a hover prefetch
  # would call /link/token/create each time the pointer crossed the button. Found in
  # the dev log against Plaid Sandbox: four prefetches, no click.
  test "create keeps Turbo from prefetching the add-accounts route" do
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "a[href=?][data-turbo-prefetch=?][data-turbo-frame=?]",
                    edit_plaid_item_path(item, add_accounts: true), "false", "modal"
    end
  end

  # The user has been through Link by now, and the likeliest reason for a same-login
  # re-link is having forgotten the connection exists. Keeping it is the main action,
  # and it closes the warning with nothing added.
  test "create offers to keep the existing connection" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "button[type=button][data-action~=?]", "DS--dialog#close",
                    text: I18n.t("plaid_items.duplicate_warning.keep_existing")
    end
  end

  # Update mode only accepts account selection for US items, so the link would be
  # inert for an EU connection.
  test "create omits the add-accounts route for an eu connection" do
    item = create_plaid_item(name: "EU Bank", institution_id: "ins_eu", region: :eu, owner: users(:family_admin))

    post_link(institution_id: "ins_eu", institution_name: "EU Bank", region: "eu")

    assert_duplicate_warning do
      assert_select "a[href=?]", edit_plaid_item_path(item, add_accounts: true), count: 0
      # assert_select rather than assert_match: the copy contains an apostrophe, which
      # is HTML-escaped in the body but decoded by the selector's text matcher.
      assert_select "p", text: /support adding accounts to an existing/
    end
  end

  # Keeping the existing connection and adding a new one are the two choices every
  # warning offers, whatever a listed connection lets this user do, so the "or"
  # between them always has a choice on each side.
  test "create offers both choices even when no connection is actionable" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    PlaidItem.any_instance.stubs(:manageable_by?).returns(false)

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "a[href*=?]", "add_accounts", count: 0
      assert_select "button[data-action~=?]", "DS--dialog#close",
                    text: I18n.t("plaid_items.duplicate_warning.keep_existing")
      assert_select "p", text: I18n.t("plaid_items.duplicate_warning.or")
      assert_select "form[action=?]", plaid_items_path
    end
  end

  # Nothing is exchanged until the user picks "Add new connection", so that form has
  # to carry the held token back, along with everything create needs to name and
  # scope the connection, and the flag that lets it past the gate.
  test "create's warning carries the held token back for the override" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning do
      assert_select "form[action=?][method=post]", plaid_items_path do
        assert_select "input[type=hidden][name=?][value=?]", "plaid_item[public_token]", HELD_TOKEN
        assert_select "input[type=hidden][name=?][value=?]", "plaid_item[region]", "us"
        assert_select "input[type=hidden][name=?][value=?]", "plaid_item[metadata][institution][institution_id]", "ins_example"
        assert_select "input[type=hidden][name=?][value=?]", "plaid_item[metadata][institution][name]", "Example Bank"
        assert_select "input[type=hidden][name=?][value=?]", "confirm_duplicate", "1"
        # _top: a confirmed create redirects to Accounts, which has no modal frame.
        assert_select "button[data-turbo-frame=?]", "_top"
      end
    end
  end

  # An item whose first sync never landed has no institution_id, and a broken
  # connection is exactly what a user tries to re-link. Fall back to the stored name.
  test "create matches on name when the connection has no institution_id" do
    create_plaid_item(name: "Chase", institution_id: nil, owner: users(:family_admin))
    stub_plaid_provider.expects(:exchange_public_token).never

    post_link(institution_id: "ins_56", institution_name: "CHASE ")

    assert_duplicate_warning
    assert_match "Chase", response.body
  end

  # A confirmed institution_id mismatch plus a shared display name is a false
  # positive, not a match -- the fallback is only for rows with no id at all.
  test "create exchanges when only the name matches a connection with an institution_id" do
    create_plaid_item(name: "Chase", institution_id: "ins_chase", owner: users(:family_admin))

    assert_exchanges do
      post_link(institution_id: "ins_other", institution_name: "Chase")
    end
  end

  test "create exchanges when the matching connection is scheduled for deletion" do
    item = create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    item.update!(scheduled_for_deletion: true)

    assert_exchanges do
      post_link(institution_id: "ins_example", institution_name: "Example Bank")
    end
  end

  test "create exchanges when the matching connection is in the other region" do
    create_plaid_item(name: "EU Bank", institution_id: "ins_eu", region: :eu, owner: users(:family_admin))

    assert_exchanges do
      post_link(institution_id: "ins_eu", institution_name: "EU Bank")
    end
  end

  test "create exchanges when only another family has the institution" do
    create_plaid_item(family: families(:empty), name: "Example Bank", institution_id: "ins_example", owner: users(:empty))

    assert_exchanges do
      post_link(institution_id: "ins_example", institution_name: "Example Bank")
    end
  end

  # PlaidItem declares `credential_scope :per_connection`, so two housemates linking
  # their own logins at one bank hold two legitimate Items -- and a member's view of
  # the family exposes nothing of anyone else's connections.
  test "create does not hold a member's link on someone else's connection" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_admin))
    sign_in users(:family_member)

    assert_exchanges do
      post_link(institution_id: "ins_example", institution_name: "Example Bank")
    end
  end

  # Admins keep family-wide oversight, and the harm is family-wide too: the family
  # shares one Plaid client and one Item allowance, so a member's existing connection
  # really does mean an admin's new one spends a second slot.
  test "create holds an admin's link on a member's connection" do
    create_plaid_item(name: "Example Bank", institution_id: "ins_example", owner: users(:family_member))
    stub_plaid_provider.expects(:exchange_public_token).never

    post_link(institution_id: "ins_example", institution_name: "Example Bank")

    assert_duplicate_warning
  end

  test "create denies a guest" do
    guest = users(:family_member)
    guest.update!(role: :guest)
    sign_in guest
    stub_plaid_provider.expects(:exchange_public_token).never

    post_link(institution_id: "ins_example", institution_name: "Example Bank", confirm: true)

    assert_response :forbidden
  end

  # A held token can outlive its 30-minute lifetime while the warning sits open, and
  # Plaid reports an expired token and an already-exchanged one the same way.
  test "create asks the user to connect again when Plaid rejects the held token" do
    stub_plaid_provider.expects(:exchange_public_token).raises(
      Plaid::ApiError.new(code: 400, response_body: {
        "error_type" => "INVALID_INPUT",
        "error_code" => "INVALID_PUBLIC_TOKEN",
        "error_message" => "could not find matching public token"
      }.to_json)
    )

    assert_no_difference "PlaidItem.count" do
      assert_difference "DebugLogEntry.count", 1 do
        post_link(institution_id: "ins_example", institution_name: "Example Bank", confirm: true)
      end
    end

    assert_select "turbo-stream[action=redirect][target=?]", accounts_path
    assert_equal I18n.t("plaid_items.create.token_expired"), flash[:alert]
    assert_no_match HELD_TOKEN, DebugLogEntry.order(:created_at).last.attributes.to_json
  end

  test "create redirects with a generic alert when the exchange fails otherwise" do
    stub_plaid_provider.expects(:exchange_public_token).raises(
      Plaid::ApiError.new(code: 500, response_body: { "error_code" => "INTERNAL_SERVER_ERROR" }.to_json)
    )

    post plaid_items_url, params: {
      plaid_item: { public_token: HELD_TOKEN, region: "us", metadata: { institution: { name: "Example Bank" } } }
    }

    assert_redirected_to accounts_path
    assert_equal I18n.t("plaid_items.create.exchange_failed"), flash[:alert]
  end

  # A hidden field has no nil: an institution id Link never reported comes back from
  # the warning's form as an empty string, which must not be stored as an id.
  test "create stores no institution_id when the form carries a blank one" do
    assert_exchanges do
      post_link(institution_id: "", institution_name: "Example Bank", confirm: true)
    end

    assert_nil PlaidItem.order(:created_at).last.institution_id
  end

  private
    # Link's onSuccess, as plaid_controller.js forwards it: the institution and its
    # accounts under metadata, and an Accept header that takes a Turbo Stream.
    def post_link(institution_id:, institution_name:, region: "us", confirm: false, accounts: nil)
      metadata = { institution: { name: institution_name, institution_id: institution_id } }
      metadata[:accounts] = accounts if accounts

      params = {
        plaid_item: {
          public_token: HELD_TOKEN,
          region: region,
          metadata: metadata
        }
      }
      params[:confirm_duplicate] = "1" if confirm

      post plaid_items_url, params: params, as: :turbo_stream
    end

    def stub_plaid_provider(region: "us")
      provider = mock
      Provider::Registry.stubs(:plaid_provider_for_region).with(region).returns(provider)
      provider
    end

    # The warning replaces the modal frame. Scoping to the stream's template keeps a
    # match anywhere else in the body from satisfying the block's assertions.
    def assert_duplicate_warning(&block)
      assert_response :success
      assert_select "turbo-stream[action=replace][target=modal] > template", &block
    end

    # One exchange, one new connection, and a stream back to Accounts -- the outcome
    # whenever the gate has nothing to hold.
    def assert_exchanges
      stub_plaid_provider.expects(:exchange_public_token).with(HELD_TOKEN).once.returns(
        OpenStruct.new(access_token: "access-sandbox-held", item_id: "item-sandbox-#{SecureRandom.hex(4)}")
      )

      assert_difference("PlaidItem.count", 1) { yield }
      assert_select "turbo-stream[action=redirect][target=?]", accounts_path
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
end
