require "application_system_test_case"

class CompactTransactionsMobileTest < ApplicationSystemTestCase
  DEFAULT_VIEWPORT_WIDTH = 1400
  DEFAULT_VIEWPORT_HEIGHT = 1400

  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    reset_viewport

    @user.update!(preferences: (@user.preferences || {}).merge(
      "preview_features_enabled" => true,
      "transactions_compact" => true
    ))

    @entry = accounts(:depository).entries.create!(
      name: "Coffee",
      date: Date.current,
      amount: 5,
      currency: "USD",
      entryable: Transaction.new
    )
  end

  test "toggling checkboxes on mobile reveals the row selection checkbox" do
    page.current_window.resize_to(375, 800)

    visit transactions_url

    checkbox = find("##{dom_id(@entry, 'selection')}", visible: false)
    assert_not checkbox.visible?, "row checkbox should start hidden on mobile"

    find("#toggle-checkboxes-button").click

    assert checkbox.visible?, "row checkbox should become visible after tapping the toggle button"
  end

  test "toggling checkboxes on mobile reveals the row selection checkbox in flat (ungrouped) view" do
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false))
    page.current_window.resize_to(375, 800)

    visit transactions_url

    checkbox = find("##{dom_id(@entry, 'selection')}", visible: false)
    assert_not checkbox.visible?, "row checkbox should start hidden on mobile"

    find("#toggle-checkboxes-button").click

    assert checkbox.visible?, "row checkbox should become visible after tapping the toggle button"
  end

  test "toggling checkboxes on mobile reveals the row selection checkbox in account activity" do
    page.current_window.resize_to(375, 800)

    visit account_url(accounts(:depository), tab: "activity")

    checkbox = find("##{dom_id(@entry, 'selection')}", visible: false)
    assert_not checkbox.visible?, "row checkbox should start hidden on mobile"

    find("#toggle-checkboxes-button").click

    assert checkbox.visible?, "row checkbox should become visible after tapping the toggle button"
  end

  private
    def ensure_tailwind_build
      return if self.class.instance_variable_defined?(:@tailwind_css_built)

      system({ "RAILS_ENV" => "test" }, "bin/rails", "tailwindcss:build", exception: true)
      self.class.instance_variable_set(:@tailwind_css_built, true)
    end

    def teardown
      reset_viewport
      super
    end

    def reset_viewport
      page.current_window.resize_to(DEFAULT_VIEWPORT_WIDTH, DEFAULT_VIEWPORT_HEIGHT) if page&.current_window
    end
end
