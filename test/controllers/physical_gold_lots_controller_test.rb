require "test_helper"

class PhysicalGoldLotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
    @account.holdings.destroy_all
    @account.investment.update!(subtype: "gold", gold_form: "physical")
  end

  test "adds a purchase to a physical gold account" do
    assert_difference -> { @account.physical_gold_lots.count }, 1 do
      post physical_gold_lots_path, params: {
        account_id: @account.id,
        physical_gold_lot: { description: "Wedding jewelry", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000, making_charge: 100, manual_value: 1_100, merchant_id: merchants(:one).id, invoice: fixture_file_upload("test.txt", "application/pdf") }
      }
    end

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal merchants(:one), @account.physical_gold_lots.last.merchant
    assert_equal "Wedding jewelry", @account.physical_gold_lots.last.description
    assert_equal 100.0, @account.physical_gold_lots.last.making_charge.to_f
    assert_equal 1_100, @account.physical_gold_lots.last.manual_value.to_f
    assert @account.physical_gold_lots.last.invoice.attached?
  end

  test "renders a new form that posts to the purchase collection" do
    get new_physical_gold_lot_path(account_id: @account.id)

    assert_response :success
    assert_select "form[action='#{physical_gold_lots_path}'][method='post'][data-turbo-frame='_top']"
    assert_select "input[type='file'][name='physical_gold_lot[invoice]']"
  end

  test "edits an individual physical gold purchase" do
    lot = @account.physical_gold_lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)

    patch physical_gold_lot_path(lot), params: { physical_gold_lot: { acquired_on: Date.current, weight: 12.5, weight_unit: "gram", karat: 22 } }

    assert_redirected_to account_path(@account, tab: "overview")
    assert_equal 12.5, lot.reload.weight.to_f
    assert_equal 22.0, lot.karat.to_f
  end

  test "renders an edit form that submits a PATCH to the purchase route" do
    lot = @account.physical_gold_lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)

    get edit_physical_gold_lot_path(lot)

    assert_response :success
    assert_select "form[action='#{physical_gold_lot_path(lot)}'][data-turbo-frame='_top'] input[name='_method'][value='patch']"
  end

  test "links an attached invoice directly from the gold overview" do
    lot = @account.physical_gold_lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)
    lot.invoice.attach(io: StringIO.new("invoice"), filename: "invoice.pdf", content_type: "application/pdf")

    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "a[href='#{physical_gold_lot_invoice_path(lot)}'][target='_blank']", count: 1
  end
end
