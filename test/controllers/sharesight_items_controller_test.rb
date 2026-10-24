require "test_helper"

class SharesightItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "create saves the API client and starts a sync" do
    post sharesight_items_url, params: { sharesight_item: { client_id: "client-id", client_secret: "client-secret" } }

    assert_redirected_to accounts_url
    item = @family.sharesight_items.sole
    assert_equal [ "client-id", "client-secret", "Sharesight" ], [ item.client_id, item.client_secret, item.name ]
    assert_equal 1, item.syncs.count
  end

  test "create without a secret shows the error in the panel" do
    post sharesight_items_url, params: { sharesight_item: { client_id: "client-id", client_secret: "" } }

    assert_redirected_to settings_providers_url
    assert_empty @family.sharesight_items
  end

  test "update keeps the stored credentials when the fields are left blank" do
    item = sharesight_item(status: :requires_update)

    patch sharesight_item_url(item), params: { sharesight_item: { client_id: "", client_secret: "" } }

    item.reload
    assert_equal [ "client-id", "client-secret" ], [ item.client_id, item.client_secret ]
    assert item.good?
  end

  test "settings panel never renders the stored secrets" do
    sharesight_item

    get connect_form_settings_providers_url(provider_key: "sharesight")

    assert_response :success
    assert_select "#sharesight-providers-panel"
    assert_no_match(/value="client-(id|secret)"/, response.body)
  end

  test "setup lists discovered portfolios" do
    item = sharesight_item
    item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42", current_balance: 1500)

    get setup_accounts_sharesight_item_url(item)

    assert_response :success
    assert_select "input[name='account_ids[]']", 1
  end

  test "completing setup creates a linked investment account with the portfolio's balance" do
    item = sharesight_item
    portfolio = item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42", current_balance: 1500, cash_balance: 0)

    assert_difference -> { @family.accounts.count }, 1 do
      post complete_account_setup_sharesight_item_url(item), params: { account_ids: [ portfolio.id ] }
    end

    assert_redirected_to accounts_url
    account = portfolio.reload.current_account
    assert_equal [ "Shares", "Investment", "brokerage", BigDecimal("1500") ],
                 [ account.name, account.accountable_type, account.accountable.subtype, account.balance ]
    assert_not item.reload.pending_account_setup?
  end

  test "setup only offers manual accounts to link" do
    item = sharesight_item
    item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42")
    manual = investment_account(owner: @user)
    plaid_linked = investment_account(owner: @user)
    plaid_linked.update_columns(plaid_account_id: plaid_accounts(:one).id)

    get setup_accounts_sharesight_item_url(item)

    assert_select "option[value=?]", manual.id
    assert_select "option[value=?]", plaid_linked.id, count: 0
  end

  test "completing setup doesn't keep an account it couldn't link" do
    item = sharesight_item
    portfolio = item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42")
    SharesightAccount.any_instance.stubs(:ensure_account_provider!).returns(nil)

    assert_no_difference -> { @family.accounts.count } do
      post complete_account_setup_sharesight_item_url(item), params: { account_ids: [ portfolio.id ] }
    end

    assert_redirected_to setup_accounts_sharesight_item_url(item)
    assert_nil portfolio.reload.current_account
  end

  test "the link dialog renders one modal frame" do
    sharesight_item

    get select_existing_account_sharesight_items_url(account_id: investment_account(owner: @user).id)

    assert_response :success
    assert_select "turbo-frame#modal", count: 1
  end

  test "links a portfolio to an existing manual investment account" do
    item = sharesight_item
    portfolio = item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42", current_balance: 1500)
    account = investment_account(owner: @user)

    post link_existing_account_sharesight_items_url, params: { account_id: account.id, sharesight_account_id: portfolio.id }

    assert_redirected_to account_url(account)
    assert_equal account, portfolio.reload.current_account
  end

  test "won't link a portfolio to an account the user can't edit" do
    item = sharesight_item
    portfolio = item.sharesight_accounts.create!(name: "Shares", currency: "AUD", sharesight_account_id: "42")
    private_account = investment_account(owner: users(:family_member))

    post link_existing_account_sharesight_items_url, params: { account_id: private_account.id, sharesight_account_id: portfolio.id }

    assert_redirected_to settings_providers_url
    assert_nil portfolio.reload.current_account
  end

  test "the accounts page shows the Sharesight connection" do
    item = sharesight_item

    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(item)}"
  end

  test "members can't change the connection" do
    item = sharesight_item
    sign_in users(:family_member)

    delete sharesight_item_url(item)

    assert_not item.reload.scheduled_for_deletion?
  end

  private

    def sharesight_item(**attributes)
      @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret", **attributes)
    end

    def investment_account(owner:)
      @family.accounts.create!(
        name: "Brokerage #{owner.id.first(4)}",
        balance: 0,
        currency: "AUD",
        owner: owner,
        accountable: Investment.new(subtype: "brokerage")
      )
    end
end
