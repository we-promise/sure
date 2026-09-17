require "test_helper"

class ValuablesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = Current.family.accounts.create!(name: "Gold", currency: "USD", balance: 0, accountable: Valuable.new)
  end

  test "account chooser offers precious metals and the new form renders" do
    get new_account_path
    assert_select "a[href*='#{new_valuable_path}']"
    get new_valuable_path
    assert_response :success
    assert_select "select[name='account[currency]']"
    assert_select "input[name='account[balance]']", count: 0
  end

  test "creates a separate accountable with an empty calculated balance" do
    assert_difference "Valuable.count", 1 do
      assert_no_difference "Investment.count" do
        post valuables_path, params: { account: { name: "Jewelry", currency: "USD", balance: 999, accountable_type: "Investment" } }
      end
    end
    account = Current.family.accounts.find_by!(name: "Jewelry")
    assert_equal "Valuable", account.accountable_type
    assert_equal "asset", account.classification
    assert_equal 0, account.balance
    assert_redirected_to account_path(account)
  end

  test "invalid creation renders errors" do
    post valuables_path, params: { account: { name: "", currency: "USD" } }
    assert_response :unprocessable_entity
  end

  test "edits metadata but cannot overwrite the calculated balance" do
    patch valuable_path(@account), params: { account: { name: "Bullion", balance: 900 } }
    assert_redirected_to account_path(@account)
    assert_equal "Bullion", @account.reload.name
    assert_equal 0, @account.balance
    get edit_account_path(@account)
    assert_response :success
  end

  test "cannot turn an investment into a precious metal through this route" do
    investment = accounts(:investment)
    patch valuable_path(investment), params: { account: { name: "Changed" } }
    assert_response :not_found
    assert_equal "Investment", investment.reload.accountable_type
  end

  test "manual refresh values the collection and supports zero overrides" do
    @account.valuable.lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 100, manual_value: 0)
    Provider::Registry.expects(:get_provider).never
    post refresh_valuation_valuable_path(@account)
    assert_redirected_to account_path(@account)
    assert_equal 0, @account.reload.balance
    assert_not @account.valuable.valuation_pending?
    assert_equal "Valuation refreshed", @account.entries.valuations.find_by!(date: Date.current).name
  end

  test "overview and activity have no statements holdings or manual balance actions" do
    get account_path(@account)
    assert_response :success
    assert_select "a[href='#{account_path(@account, tab: 'statements')}']", count: 0
    assert_select "a[href='#{account_path(@account, tab: 'holdings')}']", count: 0
    get account_path(@account, tab: "overview")
    assert_select "[role='tabpanel'][data-id='overview']" do
      assert_select "a[href='#{new_valuable_item_path(account_id: @account.id)}']", count: 0
    end
    get account_path(@account, tab: "activity")
    assert_response :success
    assert_select "a[href='#{new_valuation_path(account_id: @account.id)}']", count: 0
    assert_select "a[href='#{new_valuable_item_path(account_id: @account.id)}']"
  end

  test "overview separates bullion and appraised gemstone analysis" do
    @account.valuable.items.create!(description: "Silver bar", acquired_on: Date.current, item_type: "bullion", material: "silver", weight: 100, weight_unit: "gram", purity: 99.9, cost_amount: 100, merchant: merchants(:one))
    @account.valuable.items.create!(description: "Sapphire", acquired_on: Date.current, item_type: "gemstone", material: "sapphire", weight: 2, weight_unit: "carat", cost_amount: 100, manual_value: 500)

    get account_path(@account, tab: "overview")

    assert_select "h4", text: "Silver"
    assert_select "p", text: /Appraised value/
    assert_select "[aria-label='Test']"
  end

  test "direct securities trade requests are rejected" do
    get new_trade_path(account_id: @account.id)
    assert_response :not_found
    assert_no_difference "Trade.count" do
      post trades_path, params: { account_id: @account.id, model: { type: "buy", qty: 1, price: 10, ticker: "AAPL", date: Date.current } }
    end
    assert_response :not_found
  end

  test "read only account sharing cannot refresh or change purchases" do
    @account.update!(owner: users(:family_member))
    @account.share_with!(users(:family_admin), permission: "read_only")
    ValuableValuation.expects(:new).never
    post refresh_valuation_valuable_path(@account)
    assert_response :redirect
    assert_no_difference "ValuableItem.count" do
      post valuable_items_path, params: { account_id: @account.id, valuable_item: { description: "Unauthorized" } }
    end
    assert_response :redirect
  end
end
