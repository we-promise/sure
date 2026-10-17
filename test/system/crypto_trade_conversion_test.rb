require "application_system_test_case"

class CryptoTradeConversionTest < ApplicationSystemTestCase
  setup do
    @account = accounts(:crypto)
    @account.crypto.update!(subtype: "exchange")
    @entry = @account.entries.create!(
      name: "Crypto purchase", date: Date.current, amount: 100, currency: "USD",
      external_id: "synced-crypto-purchase", entryable: Transaction.new
    )
    sign_in users(:family_admin)
  end

  test "buy activity on a crypto exchange opens the conversion modal" do
    visit account_url(@account, tab: "activity")

    within "##{dom_id(@entry)}" do
      find("[data-activity-label-quick-edit-target='badge']").click
      find("[data-label='Buy']").click
    end

    within "turbo-frame#modal" do
      assert_selector "form[action='#{create_trade_from_transaction_transaction_path(@entry.transaction)}']"
      assert_selector "select#investment_activity_label option[value='Buy'][selected]", visible: false
      page.save_screenshot(Rails.root.join("tmp/screenshots/crypto-trade-conversion.png"))
    end
    assert_no_text "Content missing"
  end
end
