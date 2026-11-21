require "test_helper"

class ScalableCapitalItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => true))
    ScalableCapitalItem.stubs(:configured_family_id).returns(@admin.family_id)
    sign_in @admin
  end

  test "configured admin can see the connect form and queue the initial sync" do
    get connect_form_settings_providers_path(provider_key: "scalable_capital")
    assert_response :success
    assert_select "input[name='scalable_capital_item[portfolio_id]']"
    assert_includes response.body, I18n.t("scalable_capital_items.panel.trust_statement")

    assert_difference -> { @admin.family.scalable_capital_items.count } do
      post scalable_capital_items_path, params: { scalable_capital_item: { portfolio_id: "portfolio" } }
    end
    assert_redirected_to settings_providers_path(anchor: "scalable-capital-connection")
    item = @admin.family.scalable_capital_items.sole
    assert_equal @admin, item.owner
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

  test "rejects a flag as a portfolio identifier" do
    assert_no_difference -> { ScalableCapitalItem.count } do
      post scalable_capital_items_path, params: { scalable_capital_item: { portfolio_id: "--confirm" } }
    end
    assert_match(/valid Scalable account IDs/, flash[:alert])
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
