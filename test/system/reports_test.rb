require "application_system_test_case"

class ReportsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    visit reports_path(period_type: :monthly)

    # The tooltip only shows once the page's controllers are connected, so
    # keys pressed after this reach an installed hotkey.
    find("a[aria-keyshortcuts='ArrowLeft']").hover
    assert_selector "[role='tooltip']", text: "Previous period (←)"

    # Record the links the hotkeys click instead of following them. A hotkey
    # clicks synchronously, so the list is complete when the key returns.
    page.execute_script(<<~JS)
      window.clickedHotkeys = [];
      document.addEventListener("click", (event) => {
        const link = event.target.closest("a[data-hotkey]");
        if (!link) return;
        window.clickedHotkeys.push(link.dataset.hotkey);
        event.preventDefault();
      }, true);
    JS
  end

  test "the arrow keys leave section moves and dialogs alone" do
    find("section[data-section-key]", match: :first).send_keys(:enter)
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys
    page.send_keys(:escape)

    click_link I18n.t("reports.transactions_breakdown.export.google_sheets")
    assert_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_empty clicked_hotkeys

    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    page.send_keys(:arrow_left)
    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  test "a held arrow key steps one period" do
    page.execute_script(<<~JS)
      for (const repeat of [false, true, true]) {
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", repeat, bubbles: true }));
      }
    JS

    assert_equal %w[ArrowLeft], clicked_hotkeys
  end

  private
    def clicked_hotkeys
      page.evaluate_script("window.clickedHotkeys")
    end
end
