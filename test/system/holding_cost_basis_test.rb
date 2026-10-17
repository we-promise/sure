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

  private
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

    def save_cost_basis
      find(per_share_field).ancestor("form").click_on I18n.t("holdings.cost_basis_cell.save")
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
