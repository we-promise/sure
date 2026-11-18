require "application_system_test_case"

class InstitutionGroupPageTest < ApplicationSystemTestCase
  include EntriesTestHelper

  CHART_OVERLAY = "#institution-group-chart .drag-select-brush .overlay".freeze

  setup do
    @user = users(:family_admin)
    family = @user.family
    @accounts = %w[EUR GBP].map do |currency|
      family.accounts.create!(name: "Wise #{currency}", balance: 10, currency: family.currency, institution_name: "Wise", accountable: Depository.new).tap do |account|
        (0..30).each { |days| account.balances.create!(date: days.days.ago.to_date, balance: 10 + days, currency: family.currency) }
      end
    end
    create_transaction(account: @accounts.first, name: "Old Wise purchase", date: 25.days.ago.to_date, currency: family.currency)
    create_transaction(account: @accounts.second, name: "Recent Wise purchase", date: 3.days.ago.to_date, currency: family.currency)
    @slug = "depository-#{Digest::MD5.hexdigest("wise|")[0, 12]}"
    sign_in @user
  end

  test "a range dragged on the chart narrows the activity until it is cleared or a preset is picked" do
    visit institution_group_path(@slug, period: "last_30_days")
    within("#institution-group-activity") do
      assert_text "Old Wise purchase"
      assert_text "Recent Wise purchase"
    end

    drag_across_first_half

    assert_current_path(/start_date=.*end_date=/)
    within("#institution-group-activity") do
      assert_selector "#institution-group-activity-filters"
      assert_text "Old Wise purchase"
      assert_no_text "Recent Wise purchase"
    end

    find("button[aria-label^='#{I18n.t("UI.period_picker.aria_label", period: "")}']").click
    click_link "90D"

    assert_current_path(/period=last_90_days/)
    within("#institution-group-activity") do
      assert_no_selector "#institution-group-activity-filters"
      assert_text "Recent Wise purchase"
    end

    drag_across_first_half
    assert_current_path(/start_date=.*end_date=/)
    assert_no_text "Recent Wise purchase"
    find("#institution-group-activity-filters a").click

    within("#institution-group-activity") do
      assert_no_selector "#institution-group-activity-filters"
      assert_text "Recent Wise purchase"
    end
  end

  private
    # From near the start of the chart to its middle, so the range ends well
    # before the last days. The chart draws itself afresh (a new overlay)
    # whenever its size changes, as it can while the page settles, so the
    # drag goes by coordinates read once the overlay has stayed the same,
    # not by a found element, which a redraw would leave stale.
    def drag_across_first_half
      box = settled_overlay_box
      y = (box["top"] + box["height"] / 2).round

      page.driver.browser.action
        .move_to_location((box["left"] + 20).round, y)
        .click_and_hold
        .move_to_location((box["left"] + box["width"] / 2 - 20).round, y)
        .release
        .perform
    end

    def settled_overlay_box
      page.document.synchronize(10) do
        first = overlay_box
        sleep 0.3
        second = overlay_box
        raise Capybara::ExpectationNotMet, "the chart is still being drawn" unless first && first == second

        second
      end
    end

    # The overlay's place on the screen, with a mark its node keeps: a redraw
    # makes a new node, without it.
    def overlay_box
      page.evaluate_script(<<~JS)
        (() => {
          const overlay = document.querySelector("#{CHART_OVERLAY}")
          if (!overlay) return null
          overlay.dataset.drawing ||= String(Math.random())
          const box = overlay.getBoundingClientRect()
          return { drawing: overlay.dataset.drawing, left: box.left, top: box.top, width: box.width, height: box.height }
        })()
      JS
    end
end
