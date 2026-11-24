require "test_helper"

class RecurringAllocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    # credit_card is shared read-only with family_member in the fixtures, so
    # this series is visible to them but must never be mutable by them.
    @series = @family.recurring_transactions.create!(
      name: "Card Annual Fee", account: accounts(:credit_card), amount: 95,
      currency: "USD", expected_day_of_month: Date.current.day,
      anchor_date: Date.current, last_occurrence_date: Date.current,
      next_expected_date: Date.current, status: "active", manual: true
    )
    @occurrence = @series.recurring_occurrences.order(:due_on).first
  end

  test "allocation writes redirect when the family has turned recurring transactions off" do
    @family.update!(recurring_transactions_disabled: true)

    post recurring_occurrence_allocations_url(@occurrence), params: { amount: "5.00" }

    assert_redirected_to root_path
    assert_equal 0, @occurrence.reload.allocations.count
  end

  test "a read-only account share cannot record a payment" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    post recurring_occurrence_allocations_url(@occurrence), params: { amount: "5.00" }

    assert_response :not_found
    assert_equal 0, @occurrence.reload.allocations.count
  end

  test "a read-only account share cannot unlink, confirm or reject an allocation" do
    entry = accounts(:credit_card).entries.create!(
      date: Date.current, amount: 95, currency: "USD", name: "ANNUAL FEE",
      entryable: Transaction.new
    )
    suggestion = RecurringTransaction::Allocator.new(@occurrence).allocate_matched!(
      entry: entry, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
    )

    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    post confirm_recurring_allocation_url(suggestion)
    assert_response :not_found
    assert suggestion.reload.allocation_suggested?

    post reject_recurring_allocation_url(suggestion)
    assert_response :not_found
    assert RecurringAllocation.exists?(suggestion.id)

    delete recurring_allocation_url(suggestion)
    assert_response :not_found
    assert RecurringAllocation.exists?(suggestion.id)
  end

  test "the account owner records the same payment" do
    post recurring_occurrence_allocations_url(@occurrence), params: { amount: "5.00" }

    assert_redirected_to bills_url
    assert_equal 5, @occurrence.reload.allocations.sole.allocated_amount
  end

  test "a valid paid_on records the payment on that date" do
    paid = 3.days.ago.to_date

    post recurring_occurrence_allocations_url(@occurrence),
         params: { amount: "5.00", paid_on: paid.iso8601 }

    assert_redirected_to bills_url
    assert_equal paid, @occurrence.reload.allocations.sole.paid_on
  end

  test "a malformed paid_on is rejected instead of being recorded as today" do
    post recurring_occurrence_allocations_url(@occurrence),
         params: { amount: "5.00", paid_on: "not-a-date" }

    assert_redirected_to bills_url
    assert flash[:alert].present?
    assert_equal 0, @occurrence.reload.allocations.count,
      "a nil-cast date would have silently defaulted the payment to today"
  end

  test "paying with a part of a split whose original charge already pays a bill says why" do
    parent = accounts(:credit_card).entries.create!(
      date: Date.current, amount: 95, currency: "USD", name: "Card Annual Fee", entryable: Transaction.new
    )
    child, = parent.split!([ { name: "Fee", amount: 60 }, { name: "Insurance", amount: 35 } ])
    post recurring_occurrence_allocations_url(@occurrence), params: { entry_id: parent.id }

    other = @family.recurring_transactions.create!(
      name: "Card Insurance", account: accounts(:credit_card), amount: 35,
      currency: "USD", expected_day_of_month: Date.current.day,
      anchor_date: Date.current, last_occurrence_date: Date.current,
      next_expected_date: Date.current, status: "active", manual: true
    ).recurring_occurrences.order(:due_on).first
    post recurring_occurrence_allocations_url(other), params: { entry_id: child.id }

    assert_equal I18n.t("recurring_allocations.split_counterpart_allocated"), flash[:alert]
    assert_empty other.reload.allocations
  end

  test "allocation feedback is available in German" do
    expected_translations = {
      "recurring_allocations.over_allocation" => "Damit würdest du mehr als den Transaktionsbetrag zuordnen.",
      "recurring_allocations.missing_rate" => "Kein Wechselkurs verfügbar. Gib den Betrag manuell ein.",
      "recurring_allocations.already_allocated" => "Diese Transaktion ist dieser Rechnung bereits zugeordnet",
      "recurring_allocations.invalid" => "Die Zahlung konnte nicht erfasst werden",
      "recurring_allocations.create.success" => "Zahlung zugeordnet",
      "recurring_allocations.destroy.success" => "Zahlungszuordnung entfernt",
      "recurring_allocations.confirm.success" => "Zahlung der Rechnung zugeordnet",
      "recurring_allocations.reject.success" => "Vorschlag abgelehnt. Diese Transaktion wird für diese Rechnung nicht mehr vorgeschlagen."
    }

    expected_translations.each do |key, translation|
      assert_equal translation, I18n.t(key, locale: :de, fallback: false)
    end
  end

  test "confirming a suggestion on an account-less bill categorizes the transaction only for someone who may annotate it" do
    category = @family.categories.create!(name: "Card fees", color: "#e99537", lucide_icon: "shapes")
    bill = @family.recurring_transactions.create!(
      name: "Card Annual Fee", amount: 95, currency: "USD", category: category,
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true
    )
    occurrence = bill.recurring_occurrences.order(:due_on).first
    suggest = lambda do
      entry = accounts(:credit_card).entries.create!(
        date: Date.current, amount: 95, currency: "USD", name: "ANNUAL FEE", entryable: Transaction.new
      )
      suggestion = RecurringTransaction::Allocator.new(occurrence).allocate_matched!(
        entry: entry, state: "suggested", confidence: 0.7, signals: { name: 0.35 }
      )
      [ entry, suggestion ]
    end

    # family_member has the card read-only: the confirmation works, the edit does not.
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member
    entry, suggestion = suggest.call
    post confirm_recurring_allocation_url(suggestion)

    assert suggestion.reload.allocation_confirmed?
    assert_nil entry.transaction.reload.category

    sign_in @user
    entry, suggestion = suggest.call
    post confirm_recurring_allocation_url(suggestion)

    assert suggestion.reload.allocation_confirmed?
    assert_equal category, entry.transaction.reload.category
  end

  test "linking a payment categorizes the transaction only for someone who may annotate it" do
    category = @family.categories.create!(name: "Card fees", color: "#e99537", lucide_icon: "shapes")
    bill = @family.recurring_transactions.create!(
      name: "Card Annual Fee", amount: 95, currency: "USD", category: category,
      expected_day_of_month: Date.current.day, anchor_date: Date.current,
      last_occurrence_date: Date.current, next_expected_date: Date.current,
      status: "active", manual: true
    )
    occurrence = bill.recurring_occurrences.order(:due_on).first
    entry = accounts(:credit_card).entries.create!(
      date: Date.current, amount: 95, currency: "USD", name: "ANNUAL FEE", entryable: Transaction.new
    )

    # family_member has the card read-only: the link works, the edit does not.
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member
    post recurring_occurrence_allocations_url(occurrence), params: { entry_id: entry.id }

    assert_equal 1, occurrence.reload.allocations.count
    assert_nil entry.transaction.reload.category

    # The owner of the account may annotate it.
    entry.recurring_allocations.destroy_all if entry.respond_to?(:recurring_allocations)
    RecurringAllocation.where(entry: entry).destroy_all
    sign_in @user
    post recurring_occurrence_allocations_url(occurrence), params: { entry_id: entry.id }

    assert_equal category, entry.transaction.reload.category
  end
end
