require "test_helper"

class TinkoffInvestItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "create saves the token and schedules a sync" do
    post tinkoff_invest_items_url, params: {
      tinkoff_invest_item: { api_key: "tinvest-readonly-token", environment: "sandbox" }
    }

    assert_redirected_to accounts_url
    item = @family.tinkoff_invest_items.sole
    assert_equal [ "tinvest-readonly-token", "sandbox", "T-Invest (T-Bank)" ], [ item.api_key, item.environment, item.name ]
    assert_equal 1, item.syncs.count
  end

  test "create without a token rejects and redirects with alert" do
    post tinkoff_invest_items_url, params: { tinkoff_invest_item: { api_key: "", environment: "live" } }

    assert_redirected_to settings_providers_url
    assert_empty @family.tinkoff_invest_items
  end

  test "update switches environment from sandbox to live cleanly, unlinking sandbox accounts" do
    item = tinkoff_invest_item(status: :requires_update, environment: :sandbox)
    sandbox_account = item.tinkoff_invest_accounts.create!(
      name: "Sandbox Account",
      currency: "RUB",
      tinkoff_invest_account_id: "sb-acct-1",
      operations_cursor: "sb-cursor"
    )
    sure_account = investment_account(owner: @user)
    sandbox_account.ensure_account_provider!(sure_account)

    patch tinkoff_invest_item_url(item), params: {
      tinkoff_invest_item: { api_key: "", environment: "live" }
    }

    item.reload
    assert_equal "secret-token", item.api_key
    assert_equal "live", item.environment
    assert item.good?
    assert_empty item.tinkoff_invest_accounts
    assert_empty sure_account.reload.account_providers
  end

  test "update keeps stored token when blank and resets requires_update status" do
    item = tinkoff_invest_item(status: :requires_update)

    patch tinkoff_invest_item_url(item), params: {
      tinkoff_invest_item: { api_key: "", environment: "live" }
    }

    item.reload
    assert_equal "secret-token", item.api_key
    assert item.good?
  end

  test "settings panel renders root id, never leaks stored token, and shows requires_update alert" do
    tinkoff_invest_item(status: :requires_update)

    get connect_form_settings_providers_url(provider_key: "tinkoff_invest")

    assert_response :success
    assert_select "#tinkoff_invest-providers-panel"
    assert_no_match(/value="secret-token"/, response.body)
    assert_includes response.body, I18n.t("settings.providers.tinkoff_invest_panel.requires_update_title")
  end

  test "setup lists discovered accounts and completes setup with mapped subtypes" do
    item = tinkoff_invest_item
    broker = item.tinkoff_invest_accounts.create!(
      name: "IIS",
      currency: "RUB",
      tinkoff_invest_account_id: "acct-iis",
      account_type: "ACCOUNT_TYPE_TINKOFF_IIS",
      current_balance: 50_000,
      cash_balance: 5_000
    )
    box = item.tinkoff_invest_accounts.create!(
      name: "Invest Box",
      currency: "RUB",
      tinkoff_invest_account_id: "acct-box",
      account_type: "ACCOUNT_TYPE_INVEST_BOX",
      current_balance: 10_000,
      cash_balance: 1_000
    )

    get setup_accounts_tinkoff_invest_item_url(item)
    assert_response :success
    assert_select "input[name='account_ids[]']", 2

    TinkoffInvestAccount::Processor.expects(:new).never

    assert_difference -> { @family.accounts.count }, 2 do
      post complete_account_setup_tinkoff_invest_item_url(item), params: { account_ids: [ broker.id, box.id ] }
    end

    assert_redirected_to accounts_url
    assert_equal "brokerage", broker.reload.current_account.accountable.subtype
    assert_equal "other", box.reload.current_account.accountable.subtype
    assert_not item.reload.pending_account_setup?
    assert_equal 1, item.syncs.count
  end

  test "links a discovered account to an existing manual investment account asynchronously" do
    item = tinkoff_invest_item
    tinkoff_account = item.tinkoff_invest_accounts.create!(
      name: "Main Brokerage",
      currency: "RUB",
      tinkoff_invest_account_id: "acct-1",
      current_balance: 1500
    )
    account = investment_account(owner: @user)

    TinkoffInvestAccount::Processor.expects(:new).never

    post link_existing_account_tinkoff_invest_items_url, params: {
      account_id: account.id,
      tinkoff_invest_account_id: tinkoff_account.id
    }

    assert_redirected_to account_url(account)
    assert_equal account, tinkoff_account.reload.current_account
    assert_equal 1, item.syncs.count
  end

  test "accounts page displays the T-Invest connection card and requires_update badge" do
    item = tinkoff_invest_item(status: :requires_update, environment: :sandbox)

    get accounts_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(item)}"
    assert_includes response.body, I18n.t("tinkoff_invest_items.tinkoff_invest_item.requires_update")
  end

  test "non-admin members cannot delete the connection" do
    item = tinkoff_invest_item
    sign_in users(:family_member)

    delete tinkoff_invest_item_url(item)

    assert_not item.reload.scheduled_for_deletion?
  end

  private

    def tinkoff_invest_item(**attributes)
      @family.tinkoff_invest_items.create!(name: "T-Invest (T-Bank)", api_key: "secret-token", **attributes)
    end

    def investment_account(owner:)
      @family.accounts.create!(
        name: "Brokerage #{owner.id.first(4)}",
        balance: 0,
        currency: "RUB",
        owner: owner,
        accountable: Investment.new(subtype: "brokerage")
      )
    end
end
