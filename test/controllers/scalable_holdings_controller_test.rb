require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableHoldingsControllerTest < ActionDispatch::IntegrationTest
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    item = scalable_connected_item
    sign_in item.owner
    provider_account = item.scalable_accounts.create!(uid: "synthetic-portfolio", name: "Scalable Broker",
      currency: "EUR", kind: "broker", current_balance: 70, cash_balance: 50)
    provider_account.ensure_account_provider!(allow_bootstrap: true)
    account = provider_account.usable_account
    security = Security.create!(ticker: "IE00B4L5Y983", name: "Synthetic fund", offline: true)
    @holding = account.holdings.create!(security: security, account_provider: provider_account.account_provider,
      external_id: "synthetic-holding", date: Date.current, qty: 2, amount: 20, price: 10, currency: "EUR")
  end

  test "shows the snapshot without unsupported basis or security remapping forms" do
    get holding_path(@holding)
    assert_response :success
    assert_select "form[action='#{holding_path(@holding)}']", count: 0
    assert_select "form[action='#{remap_security_holding_path(@holding)}']", count: 0
    assert_select "button[data-action='click->drawer-cost-basis#toggle']", count: 0
    assert_select "button[data-action='click->holding-security-remap#toggle']", count: 0
  end

  test "rejects unsupported corrections before changing a bank snapshot or shared security" do
    patch holding_path(@holding), params: { holding: { cost_basis: "25" } }
    assert_response :forbidden
    assert_nil @holding.reload.cost_basis

    assert_no_difference "Security.count" do
      patch remap_security_holding_path(@holding), params: { security_id: "UNSUPPORTED|XETR|yahoo_finance" }
      assert_response :forbidden
    end
    assert_not @holding.reload.security_locked?

    post reset_security_holding_path(@holding)
    assert_response :forbidden
    post unlock_cost_basis_holding_path(@holding)
    assert_response :forbidden
    post sync_prices_holding_path(@holding)
    assert_response :forbidden
  end
end
