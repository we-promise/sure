require "application_system_test_case"

class PurchasesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @purchase = purchases(:allegro_awaiting)
    @purchase.update!(merchant: "Amazon.com", status: :needs_matching)
    @purchase.items.create!(name: "HEPA filter", amount: BigDecimal("249.99"), category: categories(:food_and_drink), position: 0)
    @payment = accounts(:depository).entries.create!(
      date: @purchase.ordered_on, amount: BigDecimal("249.99"), currency: "USD", name: "AMAZON MKTP", entryable: Transaction.new
    )
    @purchase.update!(match_candidate_entry_ids: [ @payment.id ])
  end

  test "link a waiting purchase to its payment and see it on the transaction" do
    visit purchases_url
    click_on I18n.t("purchases.index.tabs.to_match", count: 1)
    click_on "Amazon.com"

    click_on I18n.t("purchases.show.link")
    within "dialog" do
      click_on "AMAZON MKTP"
    end

    # The notice isn't checked here: the account sync the link starts can refresh the page and
    # take the toast with it. PurchaseLinksControllerTest checks it.
    assert_text I18n.t("purchases.statuses.matched")
    assert_text "AMAZON MKTP"
    assert_selector "a[href='#{transaction_path(@payment)}']"

    visit transaction_url(@payment)
    assert_text I18n.t("transactions.show.purchase")
    assert_text "HEPA filter"
  end
end
