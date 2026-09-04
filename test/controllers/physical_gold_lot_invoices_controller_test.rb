require "test_helper"

class PhysicalGoldLotInvoicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @account = accounts(:investment)
    @account.holdings.destroy_all
    @account.investment.update!(subtype: "gold", gold_form: "physical")
    @lot = @account.physical_gold_lots.create!(description: "Gold coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)
    @lot.invoice.attach(io: StringIO.new("invoice"), filename: "invoice.pdf", content_type: "application/pdf")
  end

  test "shows an invoice for an accessible purchase" do
    get physical_gold_lot_invoice_path(@lot)

    assert_response :redirect
    assert_match(/disposition=inline/, response.redirect_url)
  end

  test "removes an invoice for an accessible purchase" do
    delete physical_gold_lot_invoice_path(@lot)

    assert_redirected_to edit_physical_gold_lot_path(@lot)
    assert_not @lot.reload.invoice.attached?
  end

  test "does not serve an invoice to a user from another family" do
    other_user = users(:empty)
    other_user.sessions.destroy_all
    sign_in other_user

    get rails_blob_path(@lot.invoice)

    assert_response :not_found
  end

  test "does not serve an invoice from an inaccessible account in the same family" do
    other_user = users(:family_member)
    other_user.sessions.destroy_all
    sign_in other_user

    get rails_blob_path(@lot.invoice)

    assert_response :not_found
  end
end
