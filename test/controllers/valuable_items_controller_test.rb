require "test_helper"

class ValuableItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
  end

  test "adds a purchase to a physical gold account" do
    assert_difference -> { @account.valuable.lots.count }, 1 do
      post valuable_items_path, params: {
        account_id: @account.id,
        valuable_item: { description: "Wedding jewelry", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000, making_charge: 100, manual_value: 1_100, merchant_id: merchants(:one).id, invoice: fixture_file_upload("test.txt", "application/pdf") }
      }
    end

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal merchants(:one), @account.valuable.lots.last.merchant
    assert_equal "Wedding jewelry", @account.valuable.lots.last.description
    assert_equal 100.0, @account.valuable.lots.last.making_charge.to_f
    assert_equal 1_100, @account.valuable.lots.last.manual_value.to_f
    assert @account.valuable.lots.last.invoice.attached?
    assert_equal 1_100, @account.reload.balance
    assert_equal "Added Gold purchase: Wedding jewelry", @account.entries.valuations.find_by!(date: Date.current).name
  end

  test "refreshes a purchase valuation once without enqueueing a duplicate" do
    valuation = mock
    ValuableValuation.expects(:new).with(account: @account, reconciliation_name: "Added Gold purchase: Coin").returns(valuation)
    valuation.expects(:refresh!)
    RefreshValuableValuationJob.expects(:perform_later).never

    post valuable_items_path, params: {
      account_id: @account.id,
      valuable_item: {
        description: "Coin",
        acquired_on: Date.current,
        weight: 10,
        weight_unit: "gram",
        karat: 24,
        cost_amount: 1_000,
        manual_value: 1_100
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
  end

  test "editing and deleting the last purchase recalculates immediately" do
    lot = @account.valuable.lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 100, manual_value: 120)
    patch valuable_item_path(lot), params: { valuable_item: { manual_value: 150 } }
    assert_equal 150, @account.reload.balance
    assert_equal "Updated Gold purchase: Coin", @account.entries.valuations.find_by!(date: Date.current).name
    delete valuable_item_path(lot)
    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal 0, @account.reload.balance
    assert_not @account.valuable.valuation_pending?
    assert_equal "Removed Gold purchase: Coin", @account.entries.valuations.find_by!(date: Date.current).name
  end

  test "a missing quote saves the purchase and shows stale valuation feedback" do
    Provider::Registry.stubs(:get_provider).returns(nil)
    @account.update!(balance: 100)
    post valuable_items_path, params: { account_id: @account.id, valuable_item: { description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 100 } }
    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal 1, @account.valuable.lots.count
    assert_equal 100, @account.reload.balance
    assert flash[:alert].present?
    assert @account.valuable.valuation_pending?
  end

  test "rejects a merchant from another family" do
    outside_merchant = FamilyMerchant.create!(name: "Outside merchant", family: families(:empty))

    assert_no_difference -> { @account.valuable.lots.count } do
      post valuable_items_path, params: {
        account_id: @account.id,
        valuable_item: { description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000, merchant_id: outside_merchant.id }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/must belong to the account family/, response.body)
  end

  test "renders a new form that posts to the purchase collection" do
    get new_valuable_item_path(account_id: @account.id)

    assert_response :success
    assert_select "form[action='#{valuable_items_path}'][method='post'][data-turbo-frame='_top']"
    assert_select "input[type='file'][name='valuable_item[invoice]']"
    assert_select "input[name='valuable_item[weight]'][min='0.001']"
    assert_select "input[name='valuable_item[purity]'][min='0.001'][step='0.001']"
  end

  test "edits an individual physical gold purchase" do
    lot = @account.valuable.lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)

    patch valuable_item_path(lot), params: { valuable_item: { acquired_on: Date.current, weight: 12.5, weight_unit: "gram", purity: 91.667 } }

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal 12.5, lot.reload.weight.to_f
    assert_in_delta 91.667, lot.purity, 0.001
  end

  test "changing bullion to a gemstone clears its purity" do
    item = @account.valuable.items.create!(description: "Coin", acquired_on: Date.current, item_type: "bullion", material: "gold", weight: 10, weight_unit: "gram", purity: 99.9, cost_amount: 1_000, manual_value: 1_100)

    patch valuable_item_path(item), params: {
      valuable_item: {
        item_type: "gemstone",
        material: "ruby",
        weight: 1,
        weight_unit: "carat",
        purity: "",
        manual_value: 1_200
      }
    }

    assert_redirected_to account_path(@account, tab: "overview")
    assert_predicate item.reload, :gemstone?
    assert_nil item.purity
  end

  test "renders an edit form that submits a PATCH to the purchase route" do
    lot = @account.valuable.lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)

    get edit_valuable_item_path(lot)

    assert_response :success
    assert_select "form[action='#{valuable_item_path(lot)}'][data-turbo-frame='_top'] input[name='_method'][value='patch']"
  end

  test "links an attached invoice directly from the gold overview" do
    lot = @account.valuable.lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)
    lot.invoice.attach(io: StringIO.new("invoice"), filename: "invoice.pdf", content_type: "application/pdf")

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "a[href='#{valuable_item_invoice_path(lot)}'][target='_blank']", count: 1
  end
end
