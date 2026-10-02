require "application_system_test_case"

# A bill row offers a verb only when the bill needs you now, in a slot every
# row reserves from @lg, so the amounts read as one column. Below @lg rows
# carry no verb at all: the subline says why a row matters, and the drawer
# spells the verb out.
class BillRowVerbsTest < ApplicationSystemTestCase
  VERBS = %w[bills.find_payment bills.add_payment bills.review_match recurring_transactions.pay_action.pay].freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family

    # All due today, so they share This month whatever the date: every verb a
    # row can show, and two rows that show none.
    @names = []
    create_bill("Water Co", 80)                                          # Find payment
    create_bill("Comcast", 89.99, payment_url: "https://pay.example.com") # Pay
    rent = create_bill("Rent", 2150)                                     # Add payment
    current(rent).allocations.create!(allocated_amount: 500, currency: "USD", source: "user_created")
    power = create_bill("City Power", 95)                                # Review match
    RecurringAllocation.create!(recurring_occurrence: current(power), state: :suggested, source: :auto_matched,
                                allocated_amount: 95, currency: "USD", paid_on: Date.current)
    create_bill("Spotify", 11.99, autopay: true)                         # none
    gym = create_bill("Gym", 40)                                         # none, paid
    RecurringTransaction::Allocator.new(current(gym)).mark_paid!
  end

  test "amounts share one right edge whether a row has a verb or not" do
    # At 1400 both sidebars leave the list just short of @lg.
    page.current_window.resize_to(1440, 1400)
    visit bills_url
    VERBS.each { |key| assert_link I18n.t(key) }

    edges = page.evaluate_script(<<~JS, @names)
      ((names) => [...document.querySelectorAll(".\\\\@container a[href*='display=drawer']")]
        .filter((link) => names.some((name) => link.textContent.includes(name)))
        .map((link) => Math.round(link.querySelector(":scope > .text-right").getBoundingClientRect().right))
      )(arguments[0])
    JS
    assert_equal @names.size * 2, edges.size, "each bill's row in This month, and its next cycle's in After this month"
    assert_equal 1, edges.uniq.size, "amounts zig-zag: #{edges.inspect}"
  end

  test "a phone row carries no verb, and tapping it opens the drawer with one" do
    # Chrome won't shrink a window below ~500px, which leaves the list just
    # past @md. Emulate the phone itself.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: true)
    visit bills_url
    assert_text "Water Co"
    VERBS.each { |key| assert_no_link I18n.t(key) }

    find("a[data-turbo-frame='drawer']", text: "Water Co", match: :first).click
    within("dialog[open]") { assert_link I18n.t("bills.find_payment") }
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private
    def create_bill(name, amount, **attrs)
      @names << name
      @family.recurring_transactions.create!({
        name: name, account: accounts(:depository), amount: amount, currency: "USD",
        expected_day_of_month: Date.current.day, anchor_date: Date.current,
        last_occurrence_date: Date.current, next_expected_date: Date.current,
        status: "active", manual: true
      }.merge(attrs))
    end

    def current(bill)
      bill.recurring_occurrences.find_by!(due_on: Date.current)
    end
end
