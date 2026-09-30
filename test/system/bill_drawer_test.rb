require "application_system_test_case"

# A bill opens the way a transaction or a budget category does: in the drawer,
# over the list. Closing it has to put keyboard focus back on the row, or every
# bill someone checks sends them back to the top of the page.
class BillDrawerTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    # Overdue, so its row and its drawer offer Find payment, and so its row is
    # the only link to this cycle: Next up lists nothing already past due.
    due = 6.days.ago.to_date
    bill = @user.family.recurring_transactions.create!(
      name: "City Water", account: accounts(:depository), amount: 80, currency: "USD",
      expected_day_of_month: due.day, last_occurrence_date: 2.months.ago.to_date,
      next_expected_date: due, status: "active"
    )
    overdue = bill.recurring_occurrences.detect(&:overdue?)
    @row_link = "a[data-turbo-frame='drawer'][href='#{bill_path(bill, display: "drawer", occurrence: overdue.id)}']"
    @find_payment_link = "a[data-turbo-frame='drawer'][href='#{recurring_occurrence_path(overdue)}']"
  end

  # The inline expansion used to push everything below it down the page. The
  # drawer opens over the list, so closing it leaves the row where it was.
  test "on a phone, a row opens its drawer, and closing it puts focus back on the row where it was" do
    # Enough rows below it that the list scrolls, or "where it was" is a
    # position nothing could have moved.
    8.times do |i|
      due = Date.current + 10 + i
      @user.family.recurring_transactions.create!(
        name: "Later bill #{i}", account: accounts(:depository), amount: 20 + i, currency: "USD",
        expected_day_of_month: due.day, last_occurrence_date: due - 1.month,
        next_expected_date: due, status: "active"
      )
    end
    page.driver.browser.manage.window.resize_to(375, 812)
    visit bills_url
    row = find(@row_link)
    scroll_to row, align: :center
    assert_operator page.evaluate_script("document.querySelector('#main').scrollTop"), :>, 0
    top = row.evaluate_script("this.getBoundingClientRect().top")

    row.click
    within("dialog[open]") do
      assert_selector "h2", text: "City Water"
      click_on I18n.t("ds.dialog.close")
    end

    assert_no_selector "dialog[open]"
    assert_selector @row_link, focused: true
    assert_equal top, row.evaluate_script("this.getBoundingClientRect().top"), "the list moved"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  # Turbo caches the page as it was left. A drawer still open when "View full
  # bill" navigated away came back from Back as a stray, non-modal dialog.
  test "going back from the bill's page shows the list, not a leftover drawer" do
    visit bills_url

    find(@row_link).click
    within("dialog[open]") { click_on I18n.t("bills.view_full_bill") }
    assert_selector "main h1", text: "City Water"

    page.go_back
    assert_selector @row_link
    assert_no_selector "dialog[open]"
  end

  # The payment drawer's "View full bill" leaves the same way.
  test "going back from the bill's page shows the list, not a leftover payment drawer" do
    visit bills_url

    find(@find_payment_link).click
    within("dialog[open]") { click_on I18n.t("recurring_occurrences.show.view_bill") }
    assert_selector "main h1", text: "City Water"

    page.go_back
    assert_selector @row_link
    assert_no_selector "dialog[open]"
  end

  # Find payment swaps the bill's drawer for the payment drawer inside the same
  # frame, and the link that did it goes with the first one.
  test "closing the payment drawer opened from a bill's drawer returns focus to the row" do
    visit bills_url

    find(@row_link).click
    within("dialog[open]") { click_on I18n.t("bills.find_payment") }
    # Waits on a control only the payment drawer has: its "remaining" line
    # reads exactly like the bill drawer's.
    within("dialog[open]") { assert_link I18n.t("recurring_occurrences.show.mark_paid") }

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    assert_selector @row_link, focused: true
  end
end
