require "application_system_test_case"

class HoldingCostBasisTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)

    @holding = holdings(:one)
    @holding.update!(qty: 10_000, cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)
  end

  # Per share 0.0049 x 10,000 shares = 49. Rounding the pasted price to the
  # fields' two display decimals turned it into 0.00 and saved a basis of 0.
  test "a sub-cent per-share price saves the same basis typed or pasted" do
    open_cost_basis_editor
    find(per_share_field).fill_in(with: "0.0049")
    assert_field total_field_id, with: "49.00"
    save_cost_basis

    assert_equal BigDecimal("0.0049"), @holding.reload.cost_basis

    @holding.update!(cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)

    open_cost_basis_editor
    paste_into per_share_field, "0.0049"
    assert_field per_share_field_id, with: "0.0049"
    assert_field total_field_id, with: "49.00"
    save_cost_basis

    assert_equal BigDecimal("0.0049"), @holding.reload.cost_basis
  end

  # 10 x 0.0049 = 0.049. A total rounded to cents (0.05) saved 0.005 per share,
  # also when the form was saved unchanged.
  test "a sub-cent per-share price survives a total below a cent and an unchanged save" do
    @holding.update!(qty: 10)

    open_cost_basis_editor
    find(per_share_field).fill_in(with: "0.0049")
    assert_field total_field_id, with: "0.05"
    save_cost_basis

    assert_equal BigDecimal("0.0049"), @holding.reload.cost_basis

    open_cost_basis_editor
    assert_field per_share_field_id, with: "0.0049"
    save_cost_basis

    assert_equal BigDecimal("0.0049"), @holding.reload.cost_basis
  end

  test "a total fills in the per-share cost with up to four decimals" do
    @holding.update!(qty: 3)

    open_cost_basis_editor
    find("##{total_field_id}").fill_in(with: "49")
    assert_field per_share_field_id, with: "16.3333"
    save_cost_basis

    assert_equal BigDecimal("16.3333"), @holding.reload.cost_basis
  end

  # Clearing a field must clear the other one too: an empty total used to put
  # 0.00 into the submitted per-share field and lock an unknown basis as 0.
  test "clearing either field leaves the other empty and saves no basis" do
    @holding.update!(qty: 10)

    open_cost_basis_editor
    find("##{total_field_id}").fill_in(with: "49")
    assert_field per_share_field_id, with: "4.90"
    find("##{total_field_id}").fill_in(with: "", fill_options: { clear: :backspace })
    assert_field per_share_field_id, with: ""

    find(per_share_field).fill_in(with: "4.9")
    assert_field total_field_id, with: "49.00"
    find(per_share_field).fill_in(with: "", fill_options: { clear: :backspace })
    assert_field total_field_id, with: ""

    find(per_share_field).ancestor("form").click_on I18n.t("holdings.cost_basis_cell.save")
    assert_selector per_share_field
    assert_no_selector "#confirm-dialog[open]"

    assert_nil @holding.reload.cost_basis
    assert_not @holding.cost_basis_locked?
  end

  # The total field shows two decimals but is step="any", so a pasted total
  # below a cent is kept as pasted and gives the exact per-share cost.
  test "a pasted total is not rounded to the total field's two decimals" do
    @holding.update!(qty: 10)

    open_cost_basis_editor
    paste_into "##{total_field_id}", "0.049"
    assert_field total_field_id, with: "0.049"
    assert_field per_share_field_id, with: "0.0049"
    save_cost_basis

    assert_equal BigDecimal("0.0049"), @holding.reload.cost_basis

    # Unrounded pastes are written out, not in exponent notation (1.2e-7).
    open_cost_basis_editor
    paste_into per_share_field, "0.00000012"
    assert_field per_share_field_id, with: "0.00000012"
  end

  test "cancelling the confirmation keeps the holdings-list editor open and Cancel refocuses its trigger" do
    @holding.update!(qty: 10, cost_basis: 12.5, cost_basis_source: "manual", cost_basis_locked: false)

    visit account_path(@holding.account, tab: "holdings")
    trigger = find("##{dom_id(@holding, :cost_basis)} [data-DS--popover-target='button']")
    trigger.click
    field = "##{dom_id(@holding, :popover_cost_basis)}_holding_per_share_cost_basis"
    find(field).fill_in(with: "20")
    find(field).ancestor("form").click_on I18n.t("holdings.cost_basis_cell.save")

    within("#confirm-dialog") { find("button[value=cancel]").click }
    assert_no_selector "#confirm-dialog[open]"
    assert_field field.delete_prefix("#"), with: "20"

    find(field).ancestor("form").click_on I18n.t("holdings.cost_basis_cell.cancel")
    assert_no_selector field
    assert page.evaluate_script("document.activeElement.matches(\"##{dom_id(@holding, :cost_basis)} [data-DS--popover-target='button']\")")
    assert_equal BigDecimal("12.5"), @holding.reload.cost_basis
  end

  test "overwriting a cost basis asks first and keeps it when cancelled" do
    @holding.update!(qty: 10, cost_basis: 12.5, cost_basis_source: "manual", cost_basis_locked: true)

    open_cost_basis_editor
    find(per_share_field).fill_in(with: "20")
    find(per_share_field).ancestor("form").click_on I18n.t("holdings.cost_basis_cell.save")

    within "#confirm-dialog" do
      assert_text I18n.t("holdings.cost_basis_cell.overwrite_confirm_title")
      find("button[value=cancel]").click
    end

    assert_equal BigDecimal("12.5"), @holding.reload.cost_basis

    save_cost_basis
    assert_equal BigDecimal("20"), @holding.reload.cost_basis
  end

  test "the drawer editor moves focus in on open and back to the pencil on cancel" do
    open_cost_basis_editor
    assert_equal per_share_field_id, active_element_id

    find(per_share_field).ancestor("form").click_on I18n.t("holdings.cost_basis_cell.cancel")
    assert_no_selector per_share_field
    assert page.evaluate_script("document.activeElement.matches('[data-drawer-cost-basis-target=opener]')")
  end

  private
    def active_element_id
      page.evaluate_script("document.activeElement.id")
    end

    def form_id
      "#{dom_id(@holding, :drawer_cost_basis)}_holding"
    end

    def per_share_field_id
      "#{form_id}_per_share_cost_basis"
    end

    def total_field_id
      "#{form_id}_total_cost_basis"
    end

    def per_share_field
      "##{per_share_field_id}"
    end

    def open_cost_basis_editor
      visit holding_path(@holding)
      find("[data-action='click->drawer-cost-basis#toggle']").click
      assert_selector per_share_field
    end

    # A holding that already has a basis asks before overwriting it.
    def save_cost_basis
      form = find(per_share_field).ancestor("form")
      confirm = form["data-turbo-confirm"].present?
      form.click_on I18n.t("holdings.cost_basis_cell.save")
      within("#confirm-dialog") { find("button[value=confirm]", visible: true).click } if confirm
      assert_no_selector per_share_field
    end

    # Fires a real paste event so money_field#pasteAmount handles it, as it
    # does for a value copied from a statement or spreadsheet.
    def paste_into(selector, text)
      page.execute_script(<<~JS, find(selector), text)
        const [input, text] = arguments
        const data = new DataTransfer()
        data.setData("text/plain", text)
        input.focus()
        input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
      JS
    end
end
