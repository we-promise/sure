require "application_system_test_case"

class AccountsSyncUiTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "idle state shows a plain refresh trigger with no cancel control" do
    visit accounts_path

    within "#accounts-sync-controls" do
      assert_selector "button[aria-label='#{I18n.t("accounts.index.sync")}']"
      assert_no_text I18n.t("accounts.index.cancel_sync")
    end
  end

  test "an in-progress family sync shows a spinner and a matching Cancel sync button" do
    Sync.create!(syncable: @user.family, status: :syncing)

    visit accounts_path

    within "#accounts-sync-controls" do
      # `icon(..., as_button: true, class: "animate-spin")` renders a
      # DS::Button whose icon classes are fully internal to the component —
      # the caller's `class:` lands on the button element itself, not the
      # inner svg. Same visual result for a centered square icon button.
      assert_selector "button.animate-spin[disabled]"
      assert_selector "button", text: I18n.t("accounts.index.cancel_sync")
    end
  end

  test "cancelling a sync shows a flash notice that renders above the page header, not over it" do
    Sync.create!(syncable: @user.family, status: :syncing)

    visit accounts_path
    within "#accounts-sync-controls" do
      click_on I18n.t("accounts.index.cancel_sync")
    end

    assert_text I18n.t("syncs.cancel.cancelled")

    # The notification tray now renders in-flow above the page header instead
    # of as a viewport-fixed overlay — assert it actually pushes the header
    # down rather than floating on top of it.
    tray_rect = page.evaluate_script("document.querySelector('#notification-tray').getBoundingClientRect()")
    header_rect = page.evaluate_script("document.querySelector('h1').getBoundingClientRect()")

    assert tray_rect["bottom"] <= header_rect["top"],
      "expected the notification tray (bottom: #{tray_rect['bottom']}) to sit above the page header (top: #{header_rect['top']}), not overlap it"
  end
end
