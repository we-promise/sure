require "application_system_test_case"

class DeclareAndPayBillTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
  end

  test "declare rent, allocate a real payment, watch it stay partial, settle it" do
    due = Date.current + 10
    payment = @account.entries.create!(
      date: Date.current - 1, amount: 537.50, currency: "USD", name: "WATSON PROPERTY LLC",
      entryable: Transaction.new
    )

    visit bills_url
    # The switcher and the empty state both offer Add bill; either works.
    click_on I18n.t("bills.index.add_bill"), match: :first
    fill_in I18n.t("recurring_transactions.form.name_label"), with: "Watson Property"
    fill_in I18n.t("recurring_transactions.form.amount_label"), with: "2150"
    fill_in I18n.t("recurring_transactions.form.first_due_on_label"), with: due.strftime("%m/%d/%Y")
    # Account is optional (DS::Select is a custom combobox; the family
    # fallback covers candidates), so the bill is declared without one.
    click_button I18n.t("recurring_transactions.form.submit")

    assert_text "Watson Property"

    click_on I18n.t("bills.details"), match: :first
    assert_text payment.name

    # Attach the real $537.50 payment: the bill must read partial, not paid.
    within(find("div.py-2", text: payment.name, match: :first)) do
      click_on I18n.t("recurring_occurrences.show.allocate")
    end
    assert_text I18n.t("recurring_occurrences.show.remaining", amount: "$1,612.50")

    click_on I18n.t("recurring_occurrences.show.mark_paid")
    assert_text I18n.t("recurring_occurrences.mark_paid.success")

    bill = @family.recurring_transactions.find_by!(name: "Watson Property")
    occurrence = bill.recurring_occurrences.find_by!(due_on: due)
    assert occurrence.paid?
    assert_equal 2, occurrence.allocations.count
    assert_equal 2150, occurrence.allocations.sum(:allocated_amount)
  end
end
