require "application_system_test_case"

class DeclareAndPayBillTest < ApplicationSystemTestCase
  teardown do
    travel_back
  end

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @account = accounts(:depository)
  end

  test "declare rent, allocate a real payment, watch it stay partial, settle it" do
    # due lands ten days out. Late in a month that crosses into the next one,
    # which files the row under a different section with a different subline,
    # so the clock is pinned where the test's premise holds.
    travel_to Date.current.beginning_of_month + 9.days

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

    # Scan, then inspect: the row itself opens the expansion. It is due in ten
    # days, so the row carries no call to action -- there is nothing to chase
    # yet -- and the verb lives in the expansion, spelled out.
    #
    # Targeted by the frame it loads rather than by bare name: the bill also
    # appears in the summary's Next up strip, which goes to its page instead.
    # And by name within that: the index materializes the fixture family's
    # series on first visit now, so "first row" is no longer this bill.
    find("a[data-turbo-frame^='pane_recurring_occurrence_']", text: "Watson Property", match: :first).click
    within(find("turbo-frame[id^='pane_recurring_occurrence_']", match: :first)) do
      click_on I18n.t("bills.find_payment")
    end

    # Act: the drawer leads with what is owed.
    assert_text I18n.t("recurring_occurrences.show.remaining", amount: "$2,150.00")

    # This bill was declared a moment ago, so the matcher knows it only by the
    # name that was typed. "WATSON PROPERTY LLC" is not yet one of its names,
    # so there is honestly nothing to suggest -- and the wider list is open
    # rather than collapsed, because otherwise that would be a dead end.
    assert_text I18n.t("recurring_occurrences.show.no_ranked_candidates")
    assert_text payment.name

    # Attach the real $537.50 payment. Every candidate row IS its own button,
    # so there is one tap target per transaction rather than a small one beside
    # the text.
    within(find("form", text: payment.name, match: :first)) do
      find("button").click
    end

    # Linking lands back on the worklist, and the row must say the bill is
    # partly paid rather than settled: $537.50 against $2,150 is not rent.
    assert_text I18n.t("bills.attention.partial", amount: "$1,612.50")

    # Journey C picks up exactly where that leaves off: the row's verb has
    # become Add payment, and the rest is settled from the drawer.
    click_on I18n.t("bills.add_payment"), match: :first
    assert_text I18n.t("recurring_occurrences.show.remaining", amount: "$1,612.50")

    click_on I18n.t("recurring_occurrences.show.mark_paid")
    # Synchronize on durable page state, not the toast: toasts auto-dismiss on
    # their own clock and have burned CI runs before (TradesTest). The drawer's
    # remaining-amount line vanishing proves the settle round-tripped.
    assert_no_text I18n.t("recurring_occurrences.show.remaining", amount: "$1,612.50")

    bill = @family.recurring_transactions.find_by!(name: "Watson Property")
    occurrence = bill.recurring_occurrences.find_by!(due_on: due)
    assert occurrence.paid?
    assert_equal 2, occurrence.allocations.count
    assert_equal 2150, occurrence.allocations.sum(:allocated_amount)
  end

  test "declare a bill by searching every transaction and picking one" do
    charge = @account.entries.create!(
      date: Date.current - 3, amount: 537.50, currency: "USD", name: "WATSON PROPERTY LLC",
      entryable: Transaction.new
    )

    visit bills_url
    click_on I18n.t("bills.index.add_bill"), match: :first

    # A dead-end search first: nothing matches, and the way back works.
    click_on I18n.t("recurring_transactions.new.search_all_cta")
    fill_in I18n.t("recurring_transactions.pick_entry.search_placeholder"), with: "zzz-nothing"
    find("input[name='q']").send_keys(:enter)
    assert_text I18n.t("recurring_transactions.pick_entry.no_results", query: "zzz-nothing")

    click_on I18n.t("recurring_transactions.pick_entry.back")
    assert_field I18n.t("recurring_transactions.form.name_label"), with: ""

    # Now the real search: find the charge, pick it, land in a prefilled form.
    click_on I18n.t("recurring_transactions.new.search_all_cta")
    fill_in I18n.t("recurring_transactions.pick_entry.search_placeholder"), with: "WATSON"
    find("input[name='q']").send_keys(:enter)

    click_on "WATSON PROPERTY LLC"

    assert_field I18n.t("recurring_transactions.form.name_label"), with: "WATSON PROPERTY LLC"
    assert_field I18n.t("recurring_transactions.form.amount_label"), with: "537.5"
    click_button I18n.t("recurring_transactions.form.submit")

    assert_text "WATSON PROPERTY LLC"
    bill = @family.recurring_transactions.find_by!(name: "WATSON PROPERTY LLC")
    assert_equal charge.account_id, bill.account_id, "the picked entry's account rides the prefill"
  end
end
