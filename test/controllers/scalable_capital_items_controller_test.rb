require "test_helper"

class ScalableCapitalItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => true))
    ScalableCapitalItem.stubs(:configured_family_id).returns(@admin.family_id)
    sign_in @admin
  end

  test "configured admin discovers accounts and queues sync for only the selected sources" do
    client = mock
    Provider::ScalableCapital.stubs(:new).returns(client)
    client.expects(:identity).returns("person")
    client.expects(:portfolios).returns([ "portfolio-1234", "portfolio-5678" ])
    client.expects(:overnight_accounts).returns([
      { "savings_account_id" => "junior", "account" => { "display_name" => "Junior Savings", "owner_kind" => "junior", "is_active" => true } }
    ])

    get connect_form_settings_providers_path(provider_key: "scalable_capital")
    assert_response :success
    assert_select "input[name='scalable_capital_item[portfolio_id]']", count: 0
    assert_select "input[name='scalable_capital_item[savings_id]']", count: 0
    assert_includes response.body, I18n.t("scalable_capital_items.panel.trust_statement")
    assert_select "#scalable-capital-providers-panel button[type=submit].w-full", text: I18n.t("scalable_capital_items.panel.connect")

    post discover_scalable_capital_items_path
    assert_response :success
    tokens = css_select("input[name='scalable_capital_item[choices][]']").map { |input| input["value"] }
    assert_equal 3, tokens.size
    assert_includes response.body, "Junior Savings"
    assert_empty @admin.family.scalable_capital_items

    assert_difference -> { @admin.family.scalable_capital_items.count } do
      post scalable_capital_items_path, params: { scalable_capital_item: { choices: [ tokens[0], tokens[2] ] } }
    end
    assert_redirected_to settings_providers_path(anchor: "scalable-capital-connection")
    item = @admin.family.scalable_capital_items.sole
    assert_equal @admin, item.owner
    assert_equal "person", item.broker_account_id
    assert_equal [ "portfolio-1234", "junior" ], item.selected_sources.pluck("id")
    assert_equal 1, item.syncs.count
  end

  test "preview opt-in is required to create the connection" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))
    assert_no_difference -> { ScalableCapitalItem.count } do
      post scalable_capital_items_path, params: { scalable_capital_item: { portfolio_id: "portfolio" } }
    end
    assert_redirected_to root_path
  end

  test "an admin from another household cannot access the server CLI" do
    ScalableCapitalItem.stubs(:configured_family_id).returns(families(:empty).id)
    assert_no_difference -> { ScalableCapitalItem.count } do
      post scalable_capital_items_path, params: { scalable_capital_item: { portfolio_id: "portfolio" } }
    end
    assert_redirected_to settings_providers_path(anchor: "scalable-capital-connection")
  end

  test "rejects selections without an authenticated discovery token" do
    assert_no_difference -> { ScalableCapitalItem.count } do
      post scalable_capital_items_path, params: { scalable_capital_item: { choices: [ "--confirm" ] } }
    end
    assert_equal I18n.t("scalable_capital_items.create.invalid"), flash[:alert]
  end

  test "accounts renders a linked Scalable account and lets its owner enable it again" do
    item = @admin.family.scalable_capital_items.create!(portfolio_id: "portfolio", owner: @admin)
    account = item.scalable_capital_accounts.create!(kind: :brokerage)
      .create_linked_account!(balance: 125, cash_balance: 0)
    row = "#scalable-capital-accounts turbo-frame#account_#{account.id}"

    get accounts_path
    assert_response :success
    assert_select row, text: /#{Regexp.escape(account.name)}/

    patch toggle_active_account_path(account)
    follow_redirect!
    assert_predicate account.reload, :disabled?
    assert_select "#{row} button", text: I18n.t("accounts.account.enable")

    patch toggle_active_account_path(account)
    follow_redirect!
    assert_predicate account.reload, :active?
    assert_select row, count: 1
  end

  test "bank sync warns and hides refresh when an existing connection loses CLI configuration" do
    item = @admin.family.scalable_capital_items.create!(portfolio_id: "portfolio", owner: @admin)
    item.syncs.create!(status: :completed, completed_at: 10.minutes.ago)
    ScalableCapitalItem.stubs(:configured_family_id).returns(nil)
    refresh = sync_provider_settings_providers_path(provider_key: "scalable_capital")

    get settings_providers_path
    assert_response :success
    assert_select "#scalable-capital-connection" do
      assert_select "summary", text: /#{Regexp.escape(I18n.t("settings.providers.status.warn"))}/
      assert_select "form[action=?]", refresh, count: 0
      assert_select "form[action=?]", scalable_capital_item_path(item), count: 1
    end
  end

  test "disconnect removes the link and preserves the account" do
    item = @admin.family.scalable_capital_items.create!(portfolio_id: "portfolio")
    source = item.scalable_capital_accounts.create!(kind: :brokerage)
    account = source.create_linked_account!(balance: 125, cash_balance: 125)
    delete scalable_capital_item_path(item)

    assert_response :see_other
    assert_predicate account.reload, :manual?
    assert_not ScalableCapitalItem.exists?(item.id)
  end
end
