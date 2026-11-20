require "application_system_test_case"

class AccountActivityTest < ApplicationSystemTestCase
  include EntriesTestHelper

  DEFAULT_VIEWPORT_WIDTH = 1400
  DEFAULT_VIEWPORT_HEIGHT = 1400

  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    reset_viewport

    @account = accounts(:depository)
    @transaction_entry = @account.entries.create!(
      name: "Duplicate source",
      date: Date.current,
      amount: 42.50,
      currency: "USD",
      entryable: Transaction.new(category: categories(:food_and_drink))
    )
    @valuation_entry = @account.entries.create!(
      name: "Current balance",
      date: 1.day.ago.to_date,
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new
    )
  end

  test "account activity shows duplicate action for a selected transaction" do
    visit account_url(@account, tab: "activity")

    find("#" + dom_id(@transaction_entry, "selection")).check

    within "#entry-selection-bar" do
      assert_selector "a[title='Duplicate']:not(.hidden)"
    end
  end

  test "account activity hides duplicate action for a selected valuation" do
    visit account_url(@account, tab: "activity")

    find("#" + dom_id(@valuation_entry, "selection")).check

    within "#entry-selection-bar" do
      assert_selector "a[title='Duplicate'].hidden", visible: false
    end
  end

  test "account activity keeps edit for a transfer and hides delete and duplicate" do
    users(:family_admin).family.update!(manual_reconciliation: true)
    transfer = create_transfer(from_account: @account, to_account: accounts(:credit_card), amount: 100)
    outflow_entry = transfer.outflow_transaction.entry

    visit account_url(@account, tab: "activity")

    find("##{dom_id(outflow_entry, "selection")}").check

    within "#entry-selection-bar" do
      assert_selector "a[title='Edit']"
      assert_selector "a[title='Duplicate'].hidden", visible: false
      assert_selector "button[title='Delete'].hidden", visible: false
      assert_selector "button[aria-label='#{I18n.t("transactions.selection_bar.reconcile")}']"
    end
  end

  test "account activity reconciles a transfer leg through the edit drawer" do
    users(:family_admin).family.update!(manual_reconciliation: true)
    transfer = create_transfer(from_account: @account, to_account: accounts(:credit_card), amount: 100)
    outflow_entry = transfer.outflow_transaction.entry
    inflow_entry = transfer.inflow_transaction.entry

    visit account_url(@account, tab: "activity")

    find("##{dom_id(outflow_entry, "selection")}").check
    within "#entry-selection-bar" do
      find("a[title='Edit']").click
    end

    within "#bulk_transaction_edit_drawer" do
      assert_selector "input[name='bulk_update[name]']"
    end

    assert_no_selector "input[name='bulk_update[date]']"
    assert_no_selector "input[name='bulk_update[category_id]']", visible: :all
    assert_no_selector "input[name='bulk_update[merchant_id]']", visible: :all

    select I18n.t("transactions.reconcile.statuses.reconciled"), from: "bulk_update_reconciled_status"
    click_button I18n.t("transactions.bulk_updates.new.save")

    assert_selector "##{dom_id(outflow_entry)} a[aria-label='#{I18n.t("transactions.reconcile.statuses.reconciled")}']"
    assert_equal "unreconciled", inflow_entry.reload.reconciled_status
  end

  test "account activity reconciles a transfer leg with the quick action" do
    users(:family_admin).family.update!(manual_reconciliation: true)
    transfer = create_transfer(from_account: @account, to_account: accounts(:credit_card), amount: 100)
    outflow_entry = transfer.outflow_transaction.entry
    inflow_entry = transfer.inflow_transaction.entry

    visit account_url(@account, tab: "activity")

    find("##{dom_id(outflow_entry, "selection")}").check
    within "#entry-selection-bar" do
      find("button[aria-label='#{I18n.t("transactions.selection_bar.reconcile")}']").click
    end
    click_button I18n.t("transactions.reconcile.statuses.reconciled")

    assert_selector "##{dom_id(outflow_entry)} a[aria-label='#{I18n.t("transactions.reconcile.statuses.reconciled")}']"
    assert_equal "unreconciled", inflow_entry.reload.reconciled_status
  end

  test "account activity hides reconcile when only a valuation is selected" do
    users(:family_admin).family.update!(manual_reconciliation: true)

    visit account_url(@account, tab: "activity")

    find("##{dom_id(@valuation_entry, "selection")}").check

    within "#entry-selection-bar" do
      assert_selector "[data-bulk-select-target='reconcileMenu'].hidden", visible: false
      assert_selector "a[title='Edit']"
      assert_selector "button[title='Delete']"
    end
  end

  test "account activity hides reconciliation in the edit drawer for a valuation" do
    users(:family_admin).family.update!(manual_reconciliation: true)

    visit account_url(@account, tab: "activity")

    find("##{dom_id(@valuation_entry, "selection")}").check
    within "#entry-selection-bar" do
      find("a[title='Edit']").click
    end

    within "#bulk_transaction_edit_drawer" do
      assert_selector "input[name='bulk_update[name]']"
    end

    assert_no_selector "select[name='bulk_update[reconciled_status]']"
    assert_selector "input[name='bulk_update[date]']"
  end

  test "account activity hides reconcile on a synced account" do
    users(:family_admin).family.update!(manual_reconciliation: true)
    synced_account = accounts(:connected)
    entry = create_transaction(account: synced_account, name: "Synced entry")

    visit account_url(synced_account, tab: "activity")

    find("##{dom_id(entry, "selection")}").check

    within "#entry-selection-bar" do
      assert_no_selector "button[aria-label='#{I18n.t("transactions.selection_bar.reconcile")}']"
      assert_selector "a[title='Edit']"
    end
  end

  test "account activity select all includes transfer rows" do
    users(:family_admin).family.update!(manual_reconciliation: true)
    transfer = create_transfer(from_account: @account, to_account: accounts(:credit_card), amount: 100)
    outflow_entry = transfer.outflow_transaction.entry

    visit account_url(@account, tab: "activity")

    find("#selection_entry").check

    assert find("##{dom_id(outflow_entry, "selection")}").checked?
    within "#entry-selection-bar" do
      assert_selector "a[title='Edit']"
    end
  end

  test "account activity filters by reconciliation status" do
    users(:family_admin).family.update!(manual_reconciliation: true)
    @transaction_entry.update!(reconciled_status: "cleared")
    unreconciled = create_transaction(account: @account, name: "Unreconciled", amount: 10)

    visit account_url(@account, tab: "activity")

    find("#activity-filters-button").click

    within "#transaction-filters-menu" do
      find("button[data-id='reconcile_status_filter']").click
      check I18n.t("transactions.reconcile.statuses.cleared"), allow_label_click: true
      click_button "Apply"
    end

    assert_selector "##{dom_id(@transaction_entry)}"
    assert_no_selector "##{dom_id(unreconciled)}"
    assert_no_text "Content missing"
  end

  test "account activity keeps long category names from overflowing the amount on mobile" do
    category = categories(:food_and_drink)
    category.update!(name: "Super Long Category Name That Should Stop Before The Amount On Mobile")

    page.current_window.resize_to(315, 643)

    visit account_url(@account, tab: "activity")

    row = find("##{dom_id(@transaction_entry)}")
    amount = row.find("p.privacy-sensitive", visible: true)
    category_name = row.find("#category_name_mobile_#{@transaction_entry.entryable.id}", visible: true)

    assert amount.visible?
    assert category_name.visible?

    row_rect = row.native.rect
    amount_rect = amount.native.rect
    viewport_width = page.evaluate_script("window.innerWidth")
    page_scroll_width = page.evaluate_script("document.documentElement.scrollWidth")

    assert_operator amount_rect.x + amount_rect.width, :<=, row_rect.x + row_rect.width
    assert_operator page_scroll_width, :<=, viewport_width
  end

  test "account activity filter menu has no account tab and can filter by category" do
    visit account_url(@account, tab: "activity")

    find("#activity-filters-button").click

    within "#transaction-filters-menu" do
      assert_no_selector "button[data-id='account_filter']"
      assert_selector "button[data-id='category_filter']"

      find("button[data-id='category_filter']").click
      check categories(:food_and_drink).name, allow_label_click: true
      click_button "Apply"
    end

    assert_selector "#account-activity-filters li", text: categories(:food_and_drink).name
    assert_selector "##{dom_id(@transaction_entry)}"
    assert_no_selector "##{dom_id(@valuation_entry)}"
  end

  test "clearing a filter badge on account activity removes just that filter" do
    visit account_url(@account, tab: "activity", q: { categories: [ categories(:food_and_drink).filter_value ] })

    assert_selector "#account-activity-filters li", text: categories(:food_and_drink).name

    within "#account-activity-filters li", text: categories(:food_and_drink).name do
      click_button
    end

    assert_no_selector "#account-activity-filters li"
    assert_selector "##{dom_id(@valuation_entry)}"
  end

  test "account activity keeps long category names from overlapping the amount on wide screens" do
    category = categories(:food_and_drink)
    category.update!(name: "Super Long Category Name That Should Stop Before The Amount On Wide Screens Too")

    page.current_window.resize_to(1280, 900)

    visit account_url(@account, tab: "activity")

    metrics = page.evaluate_script(<<~JS)
      (() => {
        const row = document.getElementById("#{dom_id(@transaction_entry)}");
        const categoryButton = row.querySelector("##{dom_id(@transaction_entry.entryable, "category_menu_desktop")} button");
        const categoryName = categoryButton.querySelector("[data-testid='category-name']");
        const amount = row.querySelector(".privacy-sensitive");
        const categoryRect = categoryButton.getBoundingClientRect();
        const amountRect = amount.getBoundingClientRect();

        return {
          categoryRight: categoryRect.right,
          amountLeft: amountRect.left,
          categoryOverflow: categoryName.scrollWidth > categoryName.clientWidth
        };
      })()
    JS

    assert_operator metrics["categoryRight"], :<=, metrics["amountLeft"]
    assert metrics["categoryOverflow"]
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
