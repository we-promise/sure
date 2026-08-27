require "application_system_test_case"

class FindMyBillsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @account = accounts(:depository)
  end

  test "an empty Bills page finds, reviews and confirms a detected bill" do
    3.times do |i|
      @account.entries.create!(
        date: Date.current - i.months, amount: 40, currency: "USD",
        name: "GYM MEMBERSHIP", entryable: Transaction.new
      )
    end

    visit bills_url
    assert_text I18n.t("bills.index.empty.title")

    click_on I18n.t("bills.index.empty.action")

    # Detection ran synchronously; the review strip presents what it found.
    # (Case-insensitive: the strip heading renders through CSS `uppercase`.)
    assert_text(/#{Regexp.escape(I18n.t("recurring_transactions.suggested.title"))}/i)
    assert_text "GYM MEMBERSHIP"

    # Confirm inside the GYM row specifically: fixture entries can produce
    # other suggestions, and this test must not depend on their order.
    row = find(:xpath,
      "//div[contains(@class,'justify-between')][.//p[contains(normalize-space(),'GYM MEMBERSHIP')]]",
      match: :first)
    within(row) { click_on I18n.t("recurring_transactions.suggested.confirm") }

    # Confirmed on the page it was reviewed on: the bill is a worklist row now.
    assert_text I18n.t("recurring_transactions.confirmed")
    assert_current_path bills_path

    bill = @family.recurring_transactions.find_by!(name: "GYM MEMBERSHIP")
    assert bill.active?
    assert_operator bill.recurring_occurrences.count, :>, 0
  end
end
