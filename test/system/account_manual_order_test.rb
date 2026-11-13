require "application_system_test_case"

class AccountManualOrderTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(default_account_order: "manual")
    sign_in @user
  end

  test "moving an account with the keyboard saves the new order" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)
    open_groups_before = open_group_count

    within_testid("account-sidebar-tabs") do
      assert_equal [ checking.id, plaid.id ], visible_depository_ids.first(2)
      assert_no_selector "[data-sortable-list-target='item'] button", visible: true

      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] button")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)

      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }

    within_testid("account-sidebar-tabs") do
      click_button I18n.t("accounts.sidebar.sort_mode.done")
      assert_no_selector "[data-sortable-list-target='item'] button", visible: true
    end
    # Groups opened for sort mode close again.
    assert_equal open_groups_before, open_group_count

    visit account_path(checking)
    within_testid("account-sidebar-tabs") do
      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end
  end

  test "leaving sort mode saves a row still held with the keyboard" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] button")
      handle.send_keys(:enter)
      handle.send_keys(:up)

      click_button I18n.t("accounts.sidebar.sort_mode.done")
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }
  end

  test "following an account link saves a row still held with the keyboard" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] button")
      handle.send_keys(:enter)
      handle.send_keys(:up)

      find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] a[href='#{account_path(plaid)}']").click
    end

    assert_current_path account_path(plaid)
    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }
    within_testid("account-sidebar-tabs") do
      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end
  end

  test "leaving sort mode keeps focus in the sidebar when no sort toggle is visible" do
    visit account_path(accounts(:depository))

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click
    end

    # Like a tab that renders no sort toggle: nothing visible to return to.
    page.execute_script(<<~JS)
      document.querySelectorAll("[data-account-sort-mode-target='toggle']").forEach((toggle) => {
        toggle.style.display = "none";
      });
    JS

    within_testid("account-sidebar-tabs") do
      click_button I18n.t("accounts.sidebar.sort_mode.done")
    end

    assert evaluate_script(<<~JS), "focus fell back to the page body"
      document.activeElement.closest("[data-controller~='account-sort-mode']") !== null
    JS
  end

  test "a stalled save times out and reloads the saved order" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    # Order saves never answer, like a dropped mobile connection; they only
    # end when the caller aborts them. Page loads still go through.
    page.execute_script(<<~JS)
      window.realFetch = window.fetch;
      window.fetch = (url, options = {}) => {
        if (!String(url).includes("/accounts/reorder")) return window.realFetch(url, options);
        return new Promise((resolve, reject) => {
          options.signal?.addEventListener("abort", () => reject(options.signal.reason));
        });
      };
      document.querySelectorAll("[data-controller~='sortable-list']").forEach((list) => {
        list.setAttribute("data-sortable-list-save-timeout-value", "1500");
      });
    JS

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] button")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)

      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
    end

    # The failed save reloads the page, which shows the order actually saved.
    # The reload renders the whole page, which can take several seconds on CI.
    assert_eventually(timeout: 15) do
      within_testid("account-sidebar-tabs") { visible_depository_ids.first(2) == [ checking.id, plaid.id ] }
    end

    assert_nil @user.reload.manual_account_order["depository"]
  end

  test "a move is mirrored in the other sidebar tabs" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] button")
      handle.send_keys(:enter)
      handle.send_keys(:up)
      handle.send_keys(:enter)
    end

    lists = all("[data-sortable-list-url-value='#{reorder_accounts_path(group: "depository")}']", visible: :all)
    assert_operator lists.size, :>, 1
    lists.each do |list|
      ids = list.all("[data-sortable-list-target='item']", visible: :all).map { |item| item["data-sortable-list-id"] }
      assert_equal [ plaid.id, checking.id ], ids.first(2)
    end
  end

  test "a sync refresh waits while a row is held, even after focus left it" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    within_testid("account-sidebar-tabs") do
      find("button[aria-label='#{I18n.t("accounts.sidebar.sort_mode.start")}']", visible: true).click

      handle = find("[data-sortable-list-target='item'][data-sortable-list-id='#{plaid.id}'] button")
      handle.send_keys(:enter)
      handle.send_keys(:up)
    end

    # The toast a finished sync broadcasts; it would morph-refresh the page.
    # Focus has moved on, as after a touch drag or a click elsewhere.
    page.execute_script(<<~JS)
      document.activeElement.blur();
      const toast = document.createElement("div");
      toast.dataset.controller = "sync-toast";
      toast.dataset.syncToastAutoRefreshDelayValue = "100";
      document.body.appendChild(toast);
    JS
    sleep 1

    within_testid("account-sidebar-tabs") do
      assert_equal [ plaid.id, checking.id ], visible_depository_ids.first(2)
      click_button I18n.t("accounts.sidebar.sort_mode.done")
    end

    assert_eventually { @user.reload.manual_account_order["depository"]&.first(2) == [ plaid.id, checking.id ] }
  end

  test "a drag outside sort mode does not move a row" do
    checking = accounts(:depository)
    plaid = accounts(:connected)

    visit account_path(checking)

    # Like dragging an account logo or selected text: the drag starts inside
    # a row that is not draggable and is dropped at the top of the list.
    page.execute_script(<<~JS, plaid.id)
      const row = document.querySelector(`[data-sortable-list-target='item'][data-sortable-list-id='${arguments[0]}']`);
      const list = row.closest("[data-controller~='sortable-list']");
      const dataTransfer = new DataTransfer();
      row.querySelector("a").dispatchEvent(new DragEvent("dragstart", { bubbles: true, dataTransfer }));
      list.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer, clientY: 0 }));
      list.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer, clientY: 0 }));
    JS

    within_testid("account-sidebar-tabs") do
      assert_equal [ checking.id, plaid.id ], visible_depository_ids.first(2)
    end
    assert_nil @user.reload.manual_account_order["depository"]
  end

  private
    def open_group_count
      evaluate_script("document.querySelectorAll(\"[data-testid='account-sidebar-tabs'] details[open]\").length")
    end

    def visible_depository_ids
      list = all("[data-sortable-list-url-value='#{reorder_accounts_path(group: "depository")}']", visible: true).first
      list.all("[data-sortable-list-target='item']").map { |item| item["data-sortable-list-id"] }
    end

    def assert_eventually(timeout: 5)
      deadline = Time.current + timeout
      until yield
        flunk "condition not met within #{timeout}s" if Time.current > deadline
        sleep 0.1
      end
      pass
    end
end
