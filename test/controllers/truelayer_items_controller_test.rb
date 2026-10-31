require "test_helper"

class TruelayerItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "saving credentials creates an unconnected connection" do
    assert_difference -> { @family.truelayer_items.count }, 1 do
      post truelayer_items_url, params: { truelayer_item: { client_id: "test-client", client_secret: "secret" } }
    end

    item = @family.truelayer_items.last
    assert_redirected_to settings_providers_url
    assert_not item.connected?
    assert_equal "secret", item.client_secret
  end

  test "updating credentials keeps the secret when it is left blank" do
    item = credentials_item

    patch truelayer_item_url(item), params: { truelayer_item: { client_id: "sure-new", client_secret: "" } }

    item.reload
    assert_equal "sure-new", item.client_id
    assert_equal "secret", item.client_secret
  end

  test "connect redirects to TrueLayer's consent dialog" do
    credentials_item

    post connect_truelayer_items_url

    assert_response :see_other
    uri = URI.parse(response.location)
    assert_equal "auth.truelayer.com", uri.host
    assert_equal callback_truelayer_items_url, Rack::Utils.parse_query(uri.query)["redirect_uri"]
  end

  test "connecting another bank creates a new connection with the same credentials" do
    connected = credentials_item
    connected.update!(refresh_token: "r")

    assert_difference -> { @family.truelayer_items.count }, 1 do
      post connect_truelayer_items_url
    end
    new_item = @family.truelayer_items.order(:created_at).last
    assert_equal "test-client", new_item.client_id
    assert_equal "secret", new_item.client_secret
  end

  test "callback completes the connection whose state was issued to this session" do
    other = credentials_item
    other.update!(refresh_token: "other-rt")
    post connect_truelayer_items_url
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    started = @family.truelayer_items.order(:created_at).last
    assert_not_equal other, started

    Provider::Truelayer.any_instance.stubs(:exchange_code).with(code: "the-code", redirect_uri: callback_truelayer_items_url)
      .returns(access_token: "at", refresh_token: "new-rt", expires_in: 3600)
    Provider::Truelayer.any_instance.stubs(:get_me).returns({})

    get callback_truelayer_items_url, params: { code: "the-code", state: state }

    assert_redirected_to accounts_url
    assert_equal "new-rt", started.reload.refresh_token
    assert_equal "other-rt", other.reload.refresh_token
    assert_equal 1, started.syncs.count
  end

  test "callback rejects a state this session didn't issue" do
    credentials_item
    TruelayerItem.any_instance.expects(:complete_authorization!).never

    get callback_truelayer_items_url, params: { code: "the-code", state: "forged" }

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("truelayer_items.callback.invalid_callback"), flash[:alert]
  end

  test "complete account setup creates and links accounts" do
    item = credentials_item
    card = item.truelayer_accounts.create!(account_id: "c1", account_kind: "card", name: "Acme Bank - REWARDS CARD", currency: "GBP", current_balance: 50)
    skipped = item.truelayer_accounts.create!(account_id: "a1", name: "Skip me", currency: "GBP")

    assert_difference -> { @family.accounts.count }, 1 do
      post complete_account_setup_truelayer_item_url(item), params: { account_types: { card.id => "CreditCard", skipped.id => "skip" } }
    end

    account = card.reload.account
    assert_equal "CreditCard", account.accountable_type
    assert_equal 50, account.balance
    assert_nil skipped.reload.account
  end

  test "setup accounts renders the unlinked accounts" do
    ensure_tailwind_build
    item = credentials_item
    account = item.truelayer_accounts.create!(account_id: "a1", name: "Acme Bank - EVERYDAY ACCOUNT", currency: "GBP")

    get setup_accounts_truelayer_item_url(item)

    assert_response :success
    assert_select "h3", text: /Acme Bank - EVERYDAY ACCOUNT/
    assert_select "input[type=hidden][name=?]", "account_types[#{account.id}]"
    assert_select "input[type=hidden][name=?]", "account_subtypes[#{account.id}]", minimum: 1
    assert_select "input[type=date][name=sync_start_date]"
  end

  test "complete account setup stores the chosen start date, and blank clears it" do
    item = credentials_item
    account = item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")

    post complete_account_setup_truelayer_item_url(item), params: { sync_start_date: "2026-01-15", account_types: { account.id => "Depository" } }
    assert_equal Date.new(2026, 1, 15), item.reload.sync_start_date.to_date

    post complete_account_setup_truelayer_item_url(item), params: { sync_start_date: "" }
    assert_nil item.reload.sync_start_date
  end

  test "links an unlinked TrueLayer account to a manual account" do
    item = credentials_item
    truelayer_account = item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
    account = Account.create!(family: @family, name: "Manual", balance: 0, currency: "GBP", accountable: Depository.new)

    post link_existing_account_truelayer_items_url, params: { account_id: account.id, truelayer_account_id: truelayer_account.id }

    assert_redirected_to accounts_url
    assert_equal account, truelayer_account.reload.account
  end

  test "an account on a connection queued for deletion can't be linked" do
    item = credentials_item
    truelayer_account = item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
    account = Account.create!(family: @family, name: "Manual", balance: 0, currency: "GBP", accountable: Depository.new)
    item.update_column(:scheduled_for_deletion, true)

    assert_no_difference -> { AccountProvider.count } do
      post link_existing_account_truelayer_items_url, params: { account_id: account.id, truelayer_account_id: truelayer_account.id }
    end

    assert_response :not_found
    assert_nil truelayer_account.reload.account_provider
  end

  test "accounts page shows the connection card with its linked accounts" do
    ensure_tailwind_build
    item = credentials_item
    item.update!(refresh_token: "r", institution_name: "Acme Bank", name: "Acme Bank", status: :requires_update)
    truelayer_account = item.truelayer_accounts.create!(account_id: "a1", name: "Acme Bank - EVERYDAY ACCOUNT", currency: "GBP")
    account = Account.create!(family: @family, name: "Everyday Account", balance: 10, currency: "GBP", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: truelayer_account)

    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(item)}" do
      assert_select "p", text: "Acme Bank"
      assert_select "a", text: /Everyday Account/
      assert_select "button", text: /#{I18n.t("truelayer_items.truelayer_item.reconnect")}/
    end
  end

  test "settings providers page renders the TrueLayer panel" do
    ensure_tailwind_build
    credentials_item.update!(refresh_token: "r", institution_name: "Acme Bank", consent_expires_at: 3.days.from_now)

    get settings_providers_url

    assert_response :success
  end

  test "a consent started in another tab is not cancelled by a newer one" do
    credentials_item
    post connect_truelayer_items_url
    first_state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    post connect_truelayer_items_url
    second_state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    TruelayerItem.any_instance.stubs(:complete_authorization!)
    TruelayerItem.any_instance.stubs(:sync_later)

    get callback_truelayer_items_url, params: { code: "c1", state: first_state }
    assert_redirected_to accounts_url
    get callback_truelayer_items_url, params: { code: "c2", state: second_state }
    assert_redirected_to accounts_url
  end

  test "a consumed state cannot be replayed" do
    credentials_item
    post connect_truelayer_items_url
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    TruelayerItem.any_instance.stubs(:complete_authorization!)
    TruelayerItem.any_instance.stubs(:sync_later)

    get callback_truelayer_items_url, params: { code: "c1", state: state }
    assert_redirected_to accounts_url

    get callback_truelayer_items_url, params: { code: "c1", state: state }
    assert_redirected_to settings_providers_url
    assert_equal I18n.t("truelayer_items.callback.invalid_callback"), flash[:alert]
  end

  test "a credentials row with no bank connected is not shown as a connection on the Accounts page" do
    ensure_tailwind_build
    item = credentials_item

    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(item)}", count: 0
  end

  test "syncing an unconnected row redirects without starting a sync or flagging it" do
    item = credentials_item
    TruelayerItem.any_instance.expects(:sync_later).never

    post sync_truelayer_item_url(item)

    assert_redirected_to settings_providers_url
    assert item.reload.good?
  end

  test "the callback is admin-only" do
    sign_in users(:family_member)
    TruelayerItem.any_instance.expects(:complete_authorization!).never

    get callback_truelayer_items_url, params: { code: "c", state: "s" }

    assert_redirected_to accounts_url
  end

  test "reauthorize falls back to a full consent when TrueLayer refuses the reauth link" do
    item = credentials_item
    item.update!(refresh_token: "r")
    Provider::Truelayer.any_instance.expects(:reauthorization_url)
      .raises(Provider::Truelayer::TruelayerError.new("refused", :bad_request, status: 400))

    post reauthorize_truelayer_item_url(item)

    assert_response :see_other
    uri = URI.parse(response.location)
    assert_equal "auth.truelayer.com", uri.host
    assert Rack::Utils.parse_query(uri.query)["state"].present?
  end

  test "reauthorize follows the bank-hosted link TrueLayer returns" do
    item = credentials_item
    item.update!(refresh_token: "r")
    bank_url = "https://ob.hsbc.co.uk/obie/open-banking/v1.1/oauth2/authorize?client_id=abc&request=jwt"
    Provider::Truelayer.any_instance.expects(:reauthorization_url).returns(bank_url)
    Provider::Truelayer.any_instance.expects(:authorization_url).never

    post reauthorize_truelayer_item_url(item)

    assert_response :see_other
    assert_equal bank_url, response.location
  end

  test "reauthorize falls back to a full consent when the reauth link is not https" do
    item = credentials_item
    item.update!(refresh_token: "r")
    Provider::Truelayer.any_instance.expects(:reauthorization_url).returns("http://ob.hsbc.co.uk/authorize")

    post reauthorize_truelayer_item_url(item)

    assert_response :see_other
    assert_equal "auth.truelayer.com", URI.parse(response.location).host
  end

  test "a redirect to anywhere but TrueLayer is blocked" do
    credentials_item
    Provider::Truelayer.any_instance.expects(:authorization_url).returns("https://evil.example/consent")

    post connect_truelayer_items_url

    assert_redirected_to settings_providers_url
    assert_equal I18n.t("truelayer_items.redirect_blocked"), flash[:alert]
  end

  test "a look-alike host or a plain-http TrueLayer URL is blocked" do
    credentials_item
    Provider::Truelayer.any_instance.stubs(:authorization_url)
      .returns("https://truelayer.com.evil.example/consent", "http://auth.truelayer.com/consent")

    2.times do
      post connect_truelayer_items_url
      assert_redirected_to settings_providers_url
    end
  end

  test "another family's connection is not found" do
    other = families(:empty).truelayer_items.create!(name: "Other", client_id: "test-client", client_secret: "secret", refresh_token: "r")

    post sync_truelayer_item_url(other)

    assert_response :not_found
  end

  test "callback reports an error returned by TrueLayer" do
    get callback_truelayer_items_url, params: { error: "access_denied", error_description: "User cancelled" }

    assert_redirected_to settings_providers_url
    assert_includes flash[:alert], "User cancelled"
  end

  test "an unknown subtype is dropped rather than stored" do
    item = credentials_item
    account = item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")

    post complete_account_setup_truelayer_item_url(item), params: { account_types: { account.id => "Depository" }, account_subtypes: { account.id => "bogus" } }

    assert_nil account.reload.account.accountable.subtype
  end

  private

    def credentials_item
      @family.truelayer_items.create!(name: "TrueLayer Connection", client_id: "test-client", client_secret: "secret")
    end
end
