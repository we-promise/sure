require "application_system_test_case"

class InstitutionGroupPageTest < ApplicationSystemTestCase
  include EntriesTestHelper

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

    drag_across_first_half find("#institution-group-chart .drag-select-brush .overlay", visible: :all)

    assert_current_path(/start_date=.*end_date=/)
    within("#institution-group-activity") do
      assert_selector "#institution-group-activity-filters"
      assert_text "Old Wise purchase"
      assert_no_text "Recent Wise purchase"
    end

    find("button[aria-label^='#{I18n.t("UI.period_picker.aria_label", period: "")}']").click
    click_link "90D"

    within("#institution-group-activity") do
      assert_no_selector "#institution-group-activity-filters"
      assert_text "Recent Wise purchase"
    end

    drag_across_first_half find("#institution-group-chart .drag-select-brush .overlay", visible: :all)
    assert_no_text "Recent Wise purchase"
    find("#institution-group-activity-filters a").click

    within("#institution-group-activity") do
      assert_no_selector "#institution-group-activity-filters"
      assert_text "Recent Wise purchase"
    end
  end

  private
    # From near the start of the chart to its middle, so the range ends well
    # before the last days.
    def drag_across_first_half(element)
      width = element.native.rect.width

      page.driver.browser.action
        .move_to(element.native, -(width / 2 - 20).round, 0)
        .click_and_hold
        .move_by((width / 2 - 40).round, 0)
        .release
        .perform
    end
end
