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

  test "cancelling a sync shows a flash notice, and the tray centers on the content pane" do
    Sync.create!(syncable: @user.family, status: :syncing)

    visit accounts_path
    within "#accounts-sync-controls" do
      click_on I18n.t("accounts.index.cancel_sync")
    end

    assert_text I18n.t("syncs.cancel.cancelled")

    # The tray is a fixed overlay, positioned by notification_tray_controller.js
    # to center on <main> (the actual content pane next to the sidebar) rather
    # than the full viewport — assert the two centers actually match, not just
    # that the tray exists somewhere on screen.
    tray_rect = page.evaluate_script("document.querySelector('[data-notification-tray-target=\"tray\"]').getBoundingClientRect()")
    main_rect = page.evaluate_script("document.querySelector('#main').getBoundingClientRect()")

    tray_center = tray_rect["left"] + tray_rect["width"] / 2.0
    main_center = main_rect["left"] + main_rect["width"] / 2.0

    assert_in_delta main_center, tray_center, 1.0,
      "expected the tray (center: #{tray_center}) to align with the content pane (center: #{main_center}), not drift to viewport-center"
  end
end
