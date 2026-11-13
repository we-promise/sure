require "application_system_test_case"

class ConvertToTradeTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in users(:family_admin)

    # Renders the plain, required ticker field: no price provider to search,
    # no holdings to pick from.
    Security.stubs(:providers).returns([])
    @account = accounts(:investment)
    @account.holdings.delete_all
    @entry = create_transaction(account: @account, name: "Brokerage deposit", amount: 100)
  end

  # Cancel used to be a link-style button, which renders a form of its own.
  # Nested in the conversion form, the browser handed its submit button to
  # that form, so Cancel on a filled-in dialog created the trade.
  test "cancel closes a filled-in convert dialog without converting" do
    visit transaction_path(@entry)
    find("summary", text: /#{I18n.t("transactions.show.settings")}/i).click
    click_on I18n.t("transactions.show.convert")

    conversion_form = "form[action='#{create_trade_from_transaction_transaction_path(@entry.entryable)}']"
    assert_selector conversion_form

    assert_no_difference -> { Trade.count } do
      within conversion_form do
        fill_in "ticker", with: "AAPL"
        fill_in "qty", with: "1"
        click_on I18n.t("transactions.convert_to_trade.cancel")
      end

      assert_no_selector conversion_form
    end

    assert_kind_of Transaction, @entry.reload.entryable
  end
end
