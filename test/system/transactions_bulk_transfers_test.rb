require "application_system_test_case"

class TransactionsBulkTransfersTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    Entry.delete_all

    @account = accounts(:depository)
    @family = @user.family
    @family.update!(manual_reconciliation: true)

    @transfer = create_transfer(
      from_account: @account,
      to_account: accounts(:credit_card),
      amount: 100
    )
    @outflow_entry = @transfer.outflow_transaction.entry
    @inflow_entry = @transfer.inflow_transaction.entry
    @normal_entry = create_transaction(account: @account, name: "Normal entry", amount: 10)

    visit transactions_url
  end

  test "keeps edit and reconcile for a transfer and hides delete and duplicate" do
    find("##{dom_id(@outflow_entry, "selection")}").check

    within "#entry-selection-bar" do
      assert_selector "a[title='Edit']"
      assert_selector "a[title='Duplicate'].hidden", visible: false
      assert_selector "button[title='Delete'].hidden", visible: false
      assert_selector "button[aria-label='#{I18n.t("transactions.selection_bar.reconcile")}']"
    end
  end

  test "hides transfer-unsafe fields in the edit drawer" do
    find("##{dom_id(@outflow_entry, "selection")}").check

    within "#entry-selection-bar" do
      find("a[title='Edit']").click
    end

    within "#bulk_transaction_edit_drawer" do
      assert_selector "input[name='bulk_update[name]']"
    end

    assert_no_selector "input[name='bulk_update[date]']"
    assert_no_selector "input[name='bulk_update[category_id]']", visible: :all
    assert_no_selector "input[name='bulk_update[merchant_id]']", visible: :all
    assert_selector "select[name='bulk_update[tag_ids][]']"
    assert_selector "select[name='bulk_update[reconciled_status]']"
    assert_selector "textarea[name='bulk_update[notes]']"
  end

  test "shows category for a categorizable transfer outflow" do
    categorizable_transfer = create_transfer(
      from_account: @account,
      to_account: accounts(:investment),
      amount: 100
    )
    outflow_entry = categorizable_transfer.outflow_transaction.entry

    visit transactions_url
    find("##{dom_id(outflow_entry, "selection")}").check

    within "#entry-selection-bar" do
      find("a[title='Edit']").click
    end

    within "#bulk_transaction_edit_drawer" do
      assert_selector "input[name='bulk_update[name]']"
    end

    assert_selector "input[name='bulk_update[category_id]']", visible: :all
    assert_no_selector "input[name='bulk_update[merchant_id]']", visible: :all
    assert_no_selector "input[name='bulk_update[date]']"
    assert_selector "select[name='bulk_update[reconciled_status]']"
  end

  test "keeps all actions for a normal selection" do
    find("##{dom_id(@normal_entry, "selection")}").check

    within "#entry-selection-bar" do
      assert_selector "a[title='Edit']"
      assert_selector "a[title='Duplicate']"
      assert_selector "button[title='Delete']"
      assert_selector "button[aria-label='#{I18n.t("transactions.selection_bar.reconcile")}']"
    end
  end

  test "keeps category and merchant for a mixed selection" do
    find("##{dom_id(@normal_entry, "selection")}").check
    find("##{dom_id(@outflow_entry, "selection")}").check

    within "#entry-selection-bar" do
      assert_selector "a[title='Edit']"
      assert_selector "button[title='Delete'].hidden", visible: false
      find("a[title='Edit']").click
    end

    within "#bulk_transaction_edit_drawer" do
      assert_selector "input[name='bulk_update[name]']"
    end

    assert_no_selector "input[name='bulk_update[date]']"
    assert_selector "input[name='bulk_update[category_id]']", visible: :all
    assert_selector "input[name='bulk_update[merchant_id]']", visible: :all
    assert_selector "select[name='bulk_update[reconciled_status]']"
  end

  test "reconciles a transfer with the quick action" do
    find("##{dom_id(@outflow_entry, "selection")}").check

    within "#entry-selection-bar" do
      find("button[aria-label='#{I18n.t("transactions.selection_bar.reconcile")}']").click
    end
    click_button I18n.t("transactions.reconcile.statuses.reconciled")

    assert_selector "##{dom_id(@outflow_entry)} a[aria-label='#{I18n.t("transactions.reconcile.statuses.reconciled")}']"
    assert_equal "unreconciled", @inflow_entry.reload.reconciled_status
  end

  test "disables a synced transfer leg but keeps the manual leg selectable" do
    synced_transfer = create_transfer(
      from_account: accounts(:connected),
      to_account: @account,
      amount: 100
    )
    synced_outflow = synced_transfer.outflow_transaction.entry
    manual_inflow = synced_transfer.inflow_transaction.entry

    visit account_url(accounts(:connected), tab: "activity")
    assert find("##{dom_id(synced_outflow, "selection")}", visible: :all).disabled?

    visit account_url(@account, tab: "activity")
    assert_not find("##{dom_id(manual_inflow, "selection")}", visible: :all).disabled?
  end

  test "disables transfer selection when manual reconciliation is off" do
    @family.update!(manual_reconciliation: false)

    visit transactions_url

    assert find("##{dom_id(@outflow_entry, "selection")}").disabled?
  end

  test "shows the reconciliation filter for a family with manual accounts" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      assert_selector "button[data-id='reconcile_status_filter']"
    end
  end
end
