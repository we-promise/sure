require "test_helper"

class Assistant::Function::UpdateBillTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
  end

  test "amount arrives as magnitude and income keeps its sign" do
    income = create_series(name: "Paycheck", amount: -1200, bill_type: "income")

    result = call_tool(income.id, "amount" => 1300)

    assert result[:updated]
    assert_equal(-1300, income.reload.amount.to_f,
      "a raw assignment would have flipped the paycheck into a bill")
  end

  test "a non-numeric amount is refused with a hint, not raised" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "amount" => "twenty")

    assert result[:error].present?
    assert result[:hint].present?
    assert_equal 40, series.reload.amount.to_f
  end

  test "a non-finite amount is refused, not assigned" do
    # BigDecimal happily parses these strings, so the finite check is the
    # only thing between them and the ledger.
    series = create_series(name: "Gym", amount: 40)

    %w[Infinity -Infinity NaN].each do |value|
      result = call_tool(series.id, "amount" => value)

      assert result[:error].present?, "#{value} must be refused"
      assert_equal 40, series.reload.amount.to_f
    end
  end

  test "a schedule change applies the preset and pins it against detection" do
    series = create_series(name: "Gym", amount: 40)
    refute series.schedule_pinned?

    result = call_tool(series.id, "frequency" => "weekly", "weekday" => 5)

    assert result[:updated]
    assert_includes result[:changed_fields], "schedule"
    assert series.reload.schedule_pinned?,
      "an AI-applied cadence is user intent by proxy; detection must not move it back"
  end

  test "bank_reference is set and cleared like the edit dialog does" do
    series = create_series(name: "Water", amount: 80)

    result = call_tool(series.id, "bank_reference" => "VN 4711")
    assert result[:updated]
    assert_includes result[:changed_fields], "bank_reference"
    assert_equal "VN 4711", series.reload.bank_reference

    call_tool(series.id, "bank_reference" => "")
    assert_nil series.reload.bank_reference
  end

  test "reference_only is set through the tool and reported effective only with a reference" do
    series = create_series(name: "Water", amount: 80)

    result = call_tool(series.id, "bank_reference" => "VN 4711", "reference_only" => true)

    assert result[:updated]
    assert_includes result[:changed_fields], "reference_only"
    assert series.reload.reference_only?
    assert_equal true, result[:bill][:reference_only]

    assert call_tool(series.id, "reference_only" => false)[:updated]
    assert_not series.reload.reference_only?
  end

  test "a too short bank_reference is refused with the validation message" do
    series = create_series(name: "Water", amount: 80)

    result = call_tool(series.id, "bank_reference" => "ab")

    assert result[:error].present?
    assert_nil series.reload.bank_reference
  end

  test "paused maps to the stored value the UI's own Pause writes" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "status" => "paused")

    assert result[:updated]
    assert_equal "inactive", series.reload.status
    assert_equal "paused", result[:bill][:status], "but the tool answers in the UI vocabulary"
  end

  test "an amount change pins occurrences already due instead of restating them" do
    overdue_day = 10.days.ago.to_date
    series = create_series(name: "Rent", amount: 2000,
                           expected_day_of_month: overdue_day.day,
                           anchor_date: overdue_day,
                           last_occurrence_date: overdue_day << 1,
                           next_expected_date: overdue_day)
    past_due = series.recurring_occurrences.open_status.find_by!(due_on: overdue_day)

    call_tool(series.id, "amount" => 2500)

    assert_equal 2000, past_due.reload.resolved_expected_amount.to_f,
      "raising the rent must not restate what last month's unpaid rent claims"
  end

  test "an invalid renews_on is rejected instead of silently clearing" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "renews_on" => "not-a-date")

    assert_equal "renews_on is not a valid date", result[:error]
    assert_equal "Use YYYY-MM-DD.", result[:hint]
    assert_nil series.reload.renews_on

    result = call_tool(series.id, "renews_on" => "2027-03-01")

    assert result[:updated]
    assert_equal Date.new(2027, 3, 1), series.reload.renews_on
  end

  test "kind cannot leave the editable set" do
    income = create_series(name: "Paycheck", amount: -1200, bill_type: "income")

    result = call_tool(income.id, "bill_type" => "bill")

    assert result[:error].present?
    assert_equal "income", income.reload.bill_type
  end

  test "an inaccessible account name returns a hint" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "account_name" => "No Such Account")

    assert_match(/No account named/, result[:error])
    assert_includes result[:hint], "get_accounts"
  end

  test "no recognized fields is an error, not a silent no-op" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "unknown_field" => "x")

    assert_match(/No recognized fields/, result[:error])
  end

  # Sharing is per account: a read-only share reads a bill everywhere the app
  # shows it and must not change it, mirroring the pages' write guard.
  test "a read-only account share cannot update the series" do
    series = create_series(name: "Shared Sub", amount: 12, account: accounts(:credit_card))
    member = users(:family_member)

    result = Assistant::Function::UpdateBill.new(member).call("bill_id" => series.id.to_s, "name" => "Hijacked")

    assert_match(/read-only/, result[:error])
    assert_equal "Shared Sub", series.reload.name
  end

  test "the reassignment target must be writable" do
    series = create_series(name: "Wandering", amount: 9, account: nil)
    member = users(:family_member)

    result = Assistant::Function::UpdateBill.new(member).call(
      "bill_id" => series.id.to_s, "account_name" => accounts(:credit_card).name
    )

    assert_match(/add bills to/, result[:error])
    assert_nil series.reload.account_id
  end

  test "namesake accounts are refused rather than picked between" do
    series = create_series(name: "Gym", amount: 40)
    @family.accounts.create!(
      name: accounts(:depository).name, balance: 0, currency: "USD",
      accountable: Depository.new, owner: @user
    )

    result = call_tool(series.id, "account_name" => accounts(:depository).name)

    assert_match(/More than one account/, result[:error])
  end

  test "frequency once lands on the current due date, not the original anchor" do
    series = create_series(name: "Tuition", amount: 500)
    current_due = series.next_due_date
    stale_anchor = current_due - 200
    series.update_columns(anchor_date: stale_anchor)

    result = call_tool(series.id, "frequency" => "once")

    assert result[:updated], result[:error]
    series.reload
    assert_equal current_due, series.anchor_date
    assert_includes series.recurring_occurrences.pluck(:due_on), current_due
    assert_not_includes series.recurring_occurrences.pluck(:due_on), stale_anchor
    assert_empty series.recurring_occurrences.where("due_on > ?", current_due)
  end

  test "an unrecognized frequency is rejected before anything saves" do
    series = create_series(name: "Insurance", amount: 60)

    result = call_tool(series.id, "frequency" => "yearly", "name" => "Renamed")

    assert_match(/not a frequency/, result[:error])
    assert_equal "Insurance", series.reload.name, "companion edits must not save with a rejected cadence"
  end

  test "day details without a frequency are refused, not silently dropped" do
    series = create_series(name: "Rent", amount: 2150)

    result = call_tool(series.id, "due_day_of_month" => 5)

    assert_match(/need frequency/, result[:error])
  end

  test "unrecognized status and kind values error instead of no-opping" do
    series = create_series(name: "Gym", amount: 40)

    assert_match(/not a status/, call_tool(series.id, "status" => "cancelled")[:error])
    assert_match(/not a kind/, call_tool(series.id, "bill_type" => "loan")[:error])
  end

  # The tool applies every field in memory and saves once, so whatever reacts
  # to the activation must read the saved change, not the status after save.
  test "activating a detected bill links its past payments" do
    paid_on = Date.current.beginning_of_month + 8.days - 2.months
    series = create_series(name: "CITY WATER", amount: 80, status: "suggested", manual: false,
                           anchor_date: nil, expected_day_of_month: 9, last_occurrence_date: paid_on)
    entry = accounts(:depository).entries.create!(
      date: paid_on, amount: 80, currency: "USD", name: "CITY WATER", entryable: Transaction.new
    )

    assert_difference -> { series.recurring_occurrences.paid.where(due_on: paid_on).count }, 1 do
      assert call_tool(series.id, "status" => "active")[:updated]
    end
    assert RecurringAllocation.where(entry_id: entry.id, state: "confirmed").exists?
  end

  test "resuming a paused bill does not reconstruct its history" do
    paid_on = Date.current.beginning_of_month + 8.days - 2.months
    series = create_series(name: "CITY WATER", amount: 80, status: "inactive", manual: false,
                           anchor_date: nil, expected_day_of_month: 9, last_occurrence_date: paid_on)
    accounts(:depository).entries.create!(
      date: paid_on, amount: 80, currency: "USD", name: "CITY WATER", entryable: Transaction.new
    )

    assert_no_difference -> { series.recurring_occurrences.where(due_on: paid_on).count } do
      assert call_tool(series.id, "status" => "active")[:updated]
    end
  end

  test "re-anchoring a custom series rebuilds its open future and leaves paid history alone" do
    series = hairdresser_with_paid_history
    paid = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 10, 27))

    travel_to Date.new(2026, 11, 23) do
      assert_equal %w[2026-11-17 2026-12-08 2026-12-29], open_due_dates(series).first(3)

      result = call_tool(series.id, "anchor_date" => "2026-11-24", "skip_open_before_anchor" => true)

      assert result[:updated], result[:error]
      assert_equal %w[2026-11-24 2026-12-15 2027-01-05], open_due_dates(series).first(3)
      assert_equal(
        { created: %w[2026-11-24 2026-12-15 2027-01-05 2027-01-26 2027-02-16],
          removed: %w[2026-12-08 2026-12-29 2027-01-19],
          skipped: %w[2026-11-17],
          left_open_before_anchor: [] },
        result[:occurrences]
      )
      assert_equal "skipped", series.recurring_occurrences.find_by!(due_on: Date.new(2026, 11, 17)).status

      assert_equal "paid", paid.reload.status, "a paid occurrence is history"
      assert_equal 1, paid.allocations.confirmed.count, "and so is its payment"

      series.reload
      assert_equal Date.new(2026, 11, 24), series.anchor_date
      assert series.schedule_pinned?, "a re-anchored schedule is the user's intent"
      assert_includes result[:changed_fields], "schedule"
      assert_equal({ frequency: "custom", interval_count: 3, interval_unit: "week" },
                   result[:bill].slice(:frequency, :interval_count, :interval_unit))
    end
  end

  # The leftover is still owed until the user says otherwise; it also must not
  # stand in for the anchor's own occurrence a week later.
  test "without skip_open_before_anchor the open past occurrence stays owed and is reported" do
    series = hairdresser_with_paid_history

    travel_to Date.new(2026, 11, 23) do
      result = call_tool(series.id, "anchor_date" => "2026-11-24")

      assert result[:updated], result[:error]
      assert_equal %w[2026-11-17 2026-11-24 2026-12-15 2027-01-05], open_due_dates(series).first(4)
      assert_equal %w[2026-11-17], result[:occurrences][:left_open_before_anchor]
      assert_empty result[:occurrences][:skipped]
      assert_match(/skip_open_before_anchor/, result[:note])
    end
  end

  test "dry_run previews the occurrences and writes nothing" do
    series = hairdresser_with_paid_history

    travel_to Date.new(2026, 11, 23) do
      before = database_state(series)

      preview = call_tool(series.id, "anchor_date" => "2026-11-24", "skip_open_before_anchor" => true,
                          "amount" => 35, "dry_run" => true)

      assert preview[:dry_run], preview[:error]
      assert_nil preview[:updated]
      assert_equal before, database_state(series), "a dry run must leave every row as it was"

      applied = call_tool(series.id, "anchor_date" => "2026-11-24", "skip_open_before_anchor" => true, "amount" => 35)

      assert applied[:updated], applied[:error]
      assert_equal preview[:occurrences], applied[:occurrences], "the preview is what the real call does"
      assert_equal preview[:changed_fields], applied[:changed_fields]
    end
  end

  test "a dry run that would fail validation reports the error and writes nothing" do
    series = hairdresser_with_paid_history

    travel_to Date.new(2026, 11, 23) do
      before = database_state(series)

      result = call_tool(series.id, "anchor_date" => "2026-10-20", "dry_run" => true)

      assert_match(/before 2026-10-27/, result[:error])
      assert_equal before, database_state(series)
    end
  end

  test "an amount changed in the same call keeps the old figure on what was already due" do
    series = hairdresser_with_paid_history

    travel_to Date.new(2026, 11, 23) do
      result = call_tool(series.id, "anchor_date" => "2026-11-24", "skip_open_before_anchor" => true, "amount" => 35)

      assert result[:updated], result[:error]
      series.reload
      skipped = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 11, 17))
      assert_equal 30, skipped.expected_amount.to_f, "the skipped cycle fell due at the old price"
      anchored = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 11, 24))
      assert_equal 35, anchored.resolved_expected_amount.to_f
    end
  end

  test "a monthly bill moves to a custom cadence and back" do
    travel_to Date.new(2026, 11, 23) do
      created = Assistant::Function::CreateBill.new(@user).call(
        "name" => "Gym", "amount" => 50, "first_due_on" => "2026-12-01"
      )
      series = @family.recurring_transactions.find(created[:bill][:id])
      assert_equal %w[2026-12-01 2027-01-01 2027-02-01], open_due_dates(series)

      to_custom = call_tool(series.id, "frequency" => "custom", "interval_count" => 3, "interval_unit" => "week",
                                       "anchor_date" => "2026-11-24")

      assert to_custom[:updated], to_custom[:error]
      assert_equal %w[2026-11-24 2026-12-15 2027-01-05], open_due_dates(series).first(3)
      assert_equal %w[2026-12-01 2027-01-01 2027-02-01], to_custom[:occurrences][:removed]
      assert_equal "custom", to_custom[:bill][:frequency]
      assert_equal 3, to_custom[:bill][:interval_count]
      assert_equal "week", to_custom[:bill][:interval_unit]

      to_monthly = call_tool(series.id, "frequency" => "monthly", "anchor_date" => "2026-12-05")

      assert to_monthly[:updated], to_monthly[:error]
      assert_equal %w[2026-12-05 2027-01-05 2027-02-05], open_due_dates(series)
      assert_equal "monthly", to_monthly[:bill][:frequency]
      assert_nil to_monthly[:bill][:interval_count]
      assert_equal "monthly", RecurringTransaction::FrequencyPreset.detect(series.reload).key
    end
  end

  test "interval fields are refused unless frequency is custom" do
    series = create_series(name: "Gym", amount: 40)

    with_monthly = call_tool(series.id, "frequency" => "monthly", "interval_count" => 2, "name" => "Renamed")
    assert_match(/only applies to frequency custom/, with_monthly[:error])

    alone = call_tool(series.id, "interval_count" => 2, "interval_unit" => "week")
    assert_match(/only apply to frequency custom/, alone[:error])

    assert_equal "Gym", series.reload.name, "nothing in a refused call is saved"
  end

  test "custom needs both interval fields, and days only in whole weeks" do
    series = create_series(name: "Gym", amount: 40)

    assert_match(/needs interval_unit/, call_tool(series.id, "frequency" => "custom", "interval_count" => 3)[:error])
    assert_match(/Every 10 days/, call_tool(series.id, "frequency" => "custom", "interval_count" => 10,
                                                        "interval_unit" => "day")[:error])
    assert_match(/whole number/, call_tool(series.id, "frequency" => "custom", "interval_count" => "2.5",
                                                       "interval_unit" => "week")[:error])

    result = call_tool(series.id, "frequency" => "custom", "interval_count" => 21, "interval_unit" => "day",
                                  "anchor_date" => (Date.current + 7).iso8601)

    assert result[:updated], result[:error]
    assert_equal [ 3, "week" ], result[:bill].values_at(:interval_count, :interval_unit)
  end

  test "an anchor_date before the last paid occurrence is refused" do
    series = hairdresser_with_paid_history

    travel_to Date.new(2026, 11, 23) do
      result = call_tool(series.id, "anchor_date" => "2026-10-20")

      assert_match(/before 2026-10-27/, result[:error])
      assert_equal Date.new(2026, 10, 27), series.reload.anchor_date
    end
  end

  test "an unparseable anchor_date is refused" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "anchor_date" => "24/11/2026")

    assert_equal "anchor_date is not a valid date", result[:error]
  end

  test "skip_open_before_anchor needs an anchor_date" do
    series = create_series(name: "Gym", amount: 40)

    result = call_tool(series.id, "skip_open_before_anchor" => true, "name" => "Renamed")

    assert_match(/needs anchor_date/, result[:error])
    assert_equal "Gym", series.reload.name
  end

  test "a weekday that contradicts anchor_date is refused rather than moving the anchor" do
    series = hairdresser_with_paid_history

    travel_to Date.new(2026, 11, 23) do
      result = call_tool(series.id, "frequency" => "custom", "interval_count" => 3, "interval_unit" => "week",
                                    "weekday" => 5, "anchor_date" => "2026-11-24")

      assert_match(/No occurrence/, result[:error])
      assert_equal Date.new(2026, 10, 27), series.reload.anchor_date
    end
  end

  test "an installment plan is not re-anchored, since its payment count runs from its start" do
    series = create_series(name: "Sofa", amount: 100, bill_type: "installment",
                           end_mode: "after_count", end_after_count: 6)

    result = call_tool(series.id, "anchor_date" => (Date.current + 10).iso8601)

    assert_match(/plan of 6 payments/, result[:error])
  end

  # Once rewrites the count to one before any later check could see the
  # plan, so the remaining payments would have been dropped silently.
  test "frequency once does not slip an installment plan past the re-anchoring guard" do
    series = create_series(name: "Sofa", amount: 100, bill_type: "installment",
                           end_mode: "after_count", end_after_count: 6)
    rows_before = series.recurring_occurrences.pluck(:id, :due_on, :status)

    result = call_tool(series.id, "frequency" => "once", "anchor_date" => (Date.current + 10).iso8601)

    assert_match(/plan of 6 payments/, result[:error])
    assert_equal 6, series.reload.end_after_count
    assert_equal rows_before, series.recurring_occurrences.pluck(:id, :due_on, :status)
  end

  test "a bill re-anchored beyond the generation horizon reports and shows its new start" do
    travel_to Date.new(2026, 11, 23) do
      created = Assistant::Function::CreateBill.new(@user).call(
        "name" => "Insurance", "amount" => 80, "first_due_on" => "2026-12-24"
      )
      series = @family.recurring_transactions.find(created[:bill][:id])

      result = call_tool(series.id, "anchor_date" => "2027-05-24")

      assert result[:updated], result[:error]
      assert_equal "2027-05-24", result[:bill][:next_due_date], "not a date of the grid before the new start"
      assert_equal %w[2027-05-24], open_due_dates(series), "the horizon reaches the new start"

      details = Assistant::Function::GetBillDetails.new(@user).call("bill_id" => series.id.to_s)
      assert_equal %w[2027-05-24 2027-06-24 2027-07-24], details[:upcoming_due_dates]
    end
  end

  test "an anchor that weekend handling pays the day before still opens the schedule" do
    travel_to Date.new(2026, 11, 23) do
      series = create_series(name: "Rent", amount: 900, weekend_adjust: "before")

      result = call_tool(series.id, "anchor_date" => "2026-11-28")

      assert result[:updated], result[:error]
      first = series.recurring_occurrences.find_by!(original_due_on: Date.new(2026, 11, 28))
      assert_equal Date.new(2026, 11, 27), first.due_on, "Saturday the 28th is paid on Friday the 27th"
      assert_equal "2026-11-27", result[:bill][:next_due_date]
    end
  end

  test "an anchor_date short of a full YYYY-MM-DD is refused" do
    series = create_series(name: "Gym", amount: 40)

    %w[2026-12 2026-W48-2 20261124].each do |value|
      assert_equal "anchor_date is not a valid date", call_tool(series.id, "anchor_date" => value)[:error], value
    end
  end

  private

    def call_tool(bill_id, params)
      Assistant::Function::UpdateBill.new(@user).call({ "bill_id" => bill_id.to_s }.merge(params))
    end

    # Every 3 weeks from 2026-10-27, that first visit paid. As of 2026-11-23
    # it is open on 2026-11-17 (past), 2026-12-08, 2026-12-29 and on.
    def hairdresser_with_paid_history
      travel_to Date.new(2026, 10, 27) do
        created = Assistant::Function::CreateBill.new(@user).call(
          "name" => "Hairdresser", "amount" => 30, "first_due_on" => "2026-10-27",
          "frequency" => "custom", "interval_count" => 3, "interval_unit" => "week"
        )
        assert created[:created], created[:error]

        series = @family.recurring_transactions.find(created[:bill][:id])
        first = series.recurring_occurrences.find_by!(due_on: Date.new(2026, 10, 27))
        RecurringTransaction::Allocator.new(first).mark_paid!(paid_on: Date.new(2026, 10, 27))
        series
      end
    end

    def open_due_dates(series)
      series.recurring_occurrences.open_status.order(:due_on).pluck(:due_on).map(&:iso8601)
    end

    def database_state(series)
      {
        series: RecurringTransaction.find(series.id).attributes,
        rules: RecurrenceRule.where(recurring_transaction_id: series.id).order(:id).map(&:attributes),
        occurrences: RecurringOccurrence.where(recurring_transaction_id: series.id).order(:id).map(&:attributes),
        allocations: RecurringAllocation.joins(:recurring_occurrence)
                                        .where(recurring_occurrences: { recurring_transaction_id: series.id })
                                        .order(:id).map(&:attributes),
        price_changes: series.recurring_price_changes.reload.map(&:attributes)
      }
    end

    def create_series(name:, amount:, **overrides)
      @family.recurring_transactions.create!({
        name: name,
        account: accounts(:depository),
        amount: amount,
        dedup_scope: "#{name}-#{amount}",
        currency: "USD",
        expected_day_of_month: Date.current.day,
        anchor_date: Date.current,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: Date.current,
        status: "active",
        manual: true,
        bill_type: amount.to_d.negative? ? "income" : "bill"
      }.merge(overrides))
    end
end
