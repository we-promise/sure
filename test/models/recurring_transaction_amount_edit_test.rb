require "test_helper"

# A price change means "it costs this much from now on". These pin that, because
# occurrences resolve their amount from the series live, so the natural
# behaviour is the wrong one: raising the rent restates last month's unpaid rent.
class RecurringTransactionAmountEditTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @series = @family.recurring_transactions.new(
      account: accounts(:depository), name: "Rent", amount: 1200, dedup_scope: "amt-edit",
      currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: 2.months.ago.to_date.beginning_of_month,
      next_expected_date: Date.current.beginning_of_month,
      status: "active", manual: false)
    RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: 1)
    @series.save!
    RecurringTransaction::OccurrenceGenerator.new(@series).generate!

    rows = @series.recurring_occurrences.order(:due_on).to_a
    @already_due = rows.first
    @upcoming    = rows.find { |o| o.due_on > Date.current }
    assert @already_due.due_on <= Date.current, "premise: first row is already due"
    assert @upcoming.present?, "premise: at least one future row"
  end

  test "a price rise leaves what is already due alone and applies to future dates" do
    assert_equal 1200, @already_due.resolved_expected_amount.to_i
    assert_equal 1200, @upcoming.resolved_expected_amount.to_i

    @series.update!(amount: 1300)
    [ @already_due, @upcoming ].each(&:reload)

    assert_equal 1200, @already_due.resolved_expected_amount.to_i,
      "an occurrence the user was already shown as owed must not be restated"
    assert_equal 1300, @upcoming.resolved_expected_amount.to_i,
      "future dates should cost the new amount"
  end

  test "the pin is stored, so a second edit cannot walk it forward" do
    @series.update!(amount: 1300)
    @series.update!(amount: 1400)
    @already_due.reload

    assert_equal 1200, @already_due.expected_amount.to_i
    assert_equal 1200, @already_due.resolved_expected_amount.to_i
  end

  test "a price drop pins the same way" do
    @series.update!(amount: 900)
    [ @already_due, @upcoming ].each(&:reload)

    assert_equal 1200, @already_due.resolved_expected_amount.to_i
    assert_equal 900, @upcoming.resolved_expected_amount.to_i
  end

  test "editing something other than the amount pins nothing" do
    @series.update!(notes: "moved to autopay")
    @already_due.reload

    assert_nil @already_due.expected_amount,
      "only a price change should freeze an occurrence's amount"
  end

  test "an occurrence carrying a payment keeps the amount the allocator froze" do
    entry = accounts(:depository).entries.create!(name: "part", date: @already_due.due_on,
      amount: 300, currency: "USD", entryable: Transaction.new)
    RecurringTransaction::Allocator.new(@already_due).allocate!(entry: entry, amount: 300)
    @already_due.reload
    assert_equal 1200, @already_due.expected_amount.to_i, "premise: allocator froze it"

    @series.update!(amount: 1300)
    @already_due.reload
    assert_equal 1200, @already_due.resolved_expected_amount.to_i
  end
end
