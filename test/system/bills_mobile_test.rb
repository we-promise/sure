require "application_system_test_case"
require "ostruct"

# Bills is used on a phone, and the app is installable as a PWA, so "fits a
# phone" is a correctness property rather than a polish one.
#
# The row used to carry a date column, an icon, an amount, a Details button and
# a pay action, all shrink-0. At 375px those added up to more than the row was
# wide, so the bill's own name collapsed to nothing AND the row still
# overflowed. Because <main> is `overflow-y-auto`, the CSS overflow spec
# computes its overflow-x to `auto` too, which turned one wide row into a
# whole page that scrolled sideways.
class BillsMobileTest < ApplicationSystemTestCase
  PHONE = [ 375, 812 ].freeze

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    page.driver.browser.manage.window.resize_to(*PHONE)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "no Bills view scrolls sideways on a phone" do
    # The AI chips render only with consent plus a provider, so without this
    # the overview would be measured without a whole strip it can carry.
    Provider::Registry.stubs(:preferred_llm_provider).returns(OpenStruct.new)

    # A long name, a five-figure amount and a note: the row at its widest.
    bill = @family.recurring_transactions.create!(
      name: "Watson Property Management Company LLC",
      account: accounts(:depository), amount: 12_450.75, currency: "USD",
      notes: "Account 4821, on the Amex",
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true, payment_url: "https://example.com/pay"
    )

    # Without declared income the Paycheck view is an empty state, so the view
    # nominally covered here was never the one that renders periods, heroes
    # and allocation bars.
    payday = Date.current + 3
    @family.recurring_transactions.create!(
      name: "Frito Lay Bakersfield Payroll", account: accounts(:depository),
      amount: -1840, currency: "USD", bill_type: "income",
      expected_day_of_month: payday.day, anchor_date: payday,
      last_occurrence_date: payday, next_expected_date: payday,
      status: "active", manual: true
    )

    # Detection's suggested strip: a long name fighting two buttons for a row.
    @family.recurring_transactions.create!(
      name: "Neighborhood Fitness and Racquet Club Membership",
      account: accounts(:depository), amount: 89.99, currency: "USD",
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current + 1.month,
      status: "suggested", occurrence_count: 3
    )

    %w[overview calendar paycheck all].each do |view|
      visit view == "overview" ? bills_url : bills_url(view: view)

      # The widest optional strips have to actually be on the page for the
      # measurement to mean anything.
      if view == "overview"
        assert_text I18n.t("bills.ai_prompts.due_before_paycheck")
        assert_text "Neighborhood Fitness and Racquet Club Membership"
      end

      # The management table reflows into the stacked list on a narrow
      # container; a table that merely scrolls sideways would pass the
      # document measurement below while still hiding six of its columns.
      assert_no_selector "table", visible: true if view == "all"

      assert_no_horizontal_scroll("the #{view} view")
    end

    # The bill's own page: chart, history and configuration in one column.
    visit bill_url(bill)
    assert_text bill.display_name
    assert_no_horizontal_scroll("the bill page")

    # The control for the reflow above: given its width back, the container
    # query must bring the table back, or the check proved only that a table
    # never renders at all. 1920 and not 1400, because the switch reads the
    # container: the app shell's sidebars eat ~885px before the bills column
    # gets any, and 1400 leaves it narrower than the table deserves.
    page.driver.browser.manage.window.resize_to(1920, 1400)
    visit bills_url(view: "all")
    assert_selector "table", visible: true

    # The reserved list is behind a disclosure, so its rows are only ever
    # measured with it open.
    visit bills_url(view: "paycheck")
    assert_text I18n.t("bills.paycheck.reserved_ahead")
    all("summary", text: I18n.t("bills.paycheck.reserved_ahead")).each(&:click)
    assert_no_horizontal_scroll("the paycheck view with reserved amounts open")

    # And with a row expanded, which is the widest the page ever gets.
    visit bills_url
    find("a[data-turbo-frame^='pane_recurring_occurrence_']", match: :first).click
    assert_text bill.display_name
    assert_no_horizontal_scroll("the overview with a row expanded")
  end

  # A green overflow assertion proves nothing unless it can go red, and this
  # one measures a property that is zero on most pages by accident. So: force
  # an overflow and confirm the measurement sees it.
  test "the overflow check actually detects overflow" do
    visit bills_url
    assert_no_horizontal_scroll("the overview")

    page.execute_script(<<~JS)
      const wide = document.createElement("div");
      wide.style.width = "3000px";
      wide.style.height = "1px";
      document.querySelector("#main").appendChild(wide);
    JS

    assert_raises(Minitest::Assertion) { assert_no_horizontal_scroll("a deliberately wide element") }
  end

  test "the payment drawer is escapable on a phone" do
    bill = @family.recurring_transactions.create!(
      name: "CITY WATER", account: accounts(:depository), amount: 80, currency: "USD",
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true
    )
    occurrence = bill.recurring_occurrences.order(:due_on).first

    visit recurring_occurrence_url(occurrence)

    # DS::Dialog hides its own close button below lg when responsive, which
    # leaves Esc and a 12px gutter tap as the only ways out. A phone has no Esc
    # key, so this surface renders its own.
    within("dialog") do
      assert_selector "button[aria-label='#{I18n.t("ds.dialog.close")}']", visible: true
    end
    assert_no_horizontal_scroll("the payment drawer")
  end

  private
    # The document must never be wider than the viewport, and neither must the
    # scroll container inside it.
    def assert_no_horizontal_scroll(label)
      overflow = page.evaluate_script(<<~JS)
        (() => {
          const main = document.querySelector("#main");
          return {
            doc: document.documentElement.scrollWidth - document.documentElement.clientWidth,
            main: main ? main.scrollWidth - main.clientWidth : 0
          };
        })()
      JS

      assert_operator overflow["doc"], :<=, 1, "#{label} scrolls the document sideways"
      assert_operator overflow["main"], :<=, 1, "#{label} scrolls its main content sideways"
    end
end
