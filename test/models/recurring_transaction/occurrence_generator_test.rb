require "test_helper"

class RecurringTransaction::OccurrenceGeneratorTest < ActiveSupport::TestCase
  Generator = RecurringTransaction::OccurrenceGenerator

  def setup
    @family = families(:dylan_family)
    @series = recurring_transactions(:netflix_subscription)
    @series.recurring_occurrences.delete_all
  end

  test "generates the current cycle and the horizon idempotently" do
    travel_to Date.new(2026, 8, 13) do
      created = Generator.new(@series).generate!
      occurrences = @series.recurring_occurrences.order(:due_on)

      # Day-5 monthly bill: the current cycle started Aug 5, so the
      # recently-due occurrence exists alongside the future window.
      assert_equal Date.new(2026, 8, 5), occurrences.first.due_on
      assert_operator occurrences.last.due_on, :<=, Date.new(2026, 11, 13)
      assert_operator created, :>=, 3

      assert_equal 0, Generator.new(@series).generate!, "second run inserts nothing"
    end
  end

  test "the horizon always includes the next occurrence of a slow cadence" do
    travel_to Date.new(2026, 8, 13) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "annual", day_of_month: "1", month_of_year: "3")
      @series.save!

      # insert_all bypasses the association layer, so read back fresh.
      dues = @series.recurring_occurrences.reload.pluck(:due_on)
      assert_includes dues, Date.new(2027, 3, 1), "annual occurrence beyond 90 days must still materialize"
    end
  end

  test "regenerate_future! respects closed and allocated rows" do
    travel_to Date.new(2026, 8, 13) do
      Generator.new(@series).generate!

      paid = @series.recurring_occurrences.find_by!(due_on: Date.new(2026, 9, 5))
      paid.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created")
      future = @series.recurring_occurrences.find_by!(due_on: Date.new(2026, 10, 5))

      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "20")
      @series.save!

      remaining = @series.recurring_occurrences.reload
      assert_includes remaining.map(&:id), paid.id, "allocated rows survive schedule edits"
      assert_not_includes remaining.map(&:id), future.id, "unallocated future rows are rebuilt"
      assert_includes remaining.map(&:due_on), Date.new(2026, 8, 20)
      # 15 days from the paid Sep 5 row is outside the monthly half cycle, so a
      # deliberate move to another week still gets its own occurrence.
      assert_includes remaining.map(&:due_on), Date.new(2026, 9, 20)
    end
  end

  test "pausing prunes the re-generatable future and resuming rebuilds it" do
    travel_to Date.new(2026, 8, 13) do
      Generator.new(@series).generate!
      assert_operator @series.recurring_occurrences.count, :>, 1

      @series.update!(status: "paused")
      assert_equal 0, @series.recurring_occurrences.where("due_on >= ?", Date.current).count

      @series.update!(status: "active")
      assert_operator @series.recurring_occurrences.where("due_on >= ?", Date.current).count, :>=, 3
    end
  end

  test "a declared bill's first obligation is its anchor, never a fabricated previous cycle" do
    travel_to Date.new(2026, 8, 13) do
      declared = @family.recurring_transactions.create!(
        name: "Declared rent", amount: 2150, currency: "USD",
        expected_day_of_month: 23, anchor_date: Date.new(2026, 8, 23),
        last_occurrence_date: Date.new(2026, 8, 23), next_expected_date: Date.new(2026, 8, 23),
        status: "active", manual: true
      )

      first = declared.recurring_occurrences.reload.order(:due_on).first
      assert_equal Date.new(2026, 8, 23), first.due_on, "no phantom July 23 debt"
    end
  end

  test "suggested series generate nothing" do
    @series.update!(status: "suggested")
    assert_equal 0, Generator.new(@series).generate!.to_i
    assert_empty @series.recurring_occurrences
  end

  test "occurrence identity is the raw date, so weekend adjustment does not fork rows" do
    travel_to Date.new(2026, 8, 1) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "15")
      @series.weekend_adjust = "before"
      @series.save!

      # Aug 15 2026 is a Saturday: due Friday the 14th, identity still the 15th.
      occurrence = @series.recurring_occurrences.find_by!(original_due_on: Date.new(2026, 8, 15))
      assert_equal Date.new(2026, 8, 14), occurrence.due_on

      assert_equal 0, Generator.new(@series).generate!, "adjusted occurrence does not re-insert"
    end
  end

  # #4300: detection moving a bill's due day by a day regenerates the schedule.
  # The old cycle's row survives (paid or past due), and it already is this
  # cycle, so no second occurrence may appear beside it.
  test "a due-day shift does not add a second occurrence to a paid cycle" do
    travel_to Date.new(2026, 10, 16) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "6")
      @series.save!
      paid = @series.recurring_occurrences.reload.find_by!(due_on: Date.new(2026, 10, 6))
      paid.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created")

      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "5")
      @series.save!

      dues = @series.recurring_occurrences.reload.pluck(:due_on)
      assert_not_includes dues, Date.new(2026, 10, 5)
      assert_includes dues, Date.new(2026, 11, 5)
    end
  end

  test "a due-day shift does not add a second occurrence beside an unpaid past-due one" do
    travel_to Date.new(2026, 10, 16) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "6")
      @series.save!

      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "5")
      @series.save!

      october = @series.recurring_occurrences.reload.where(due_on: Date.new(2026, 10, 1)..Date.new(2026, 10, 31))
      assert_equal [ Date.new(2026, 10, 6) ], october.pluck(:due_on)
    end
  end

  test "a later due-day shift does not duplicate the cycle either" do
    travel_to Date.new(2026, 10, 16) do
      # The fixture is already monthly on the 5th, so saving regenerates nothing.
      Generator.new(@series).generate!
      paid = @series.recurring_occurrences.reload.find_by!(due_on: Date.new(2026, 10, 5))
      paid.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created")

      RecurringTransaction::FrequencyPreset.apply(@series, preset: "monthly", day_of_month: "6")
      @series.save!

      dues = @series.recurring_occurrences.reload.pluck(:due_on)
      assert_not_includes dues, Date.new(2026, 10, 6)
      assert_includes dues, Date.new(2026, 11, 6)
    end
  end

  # Two days of one schedule a few days apart are both real occurrences: only
  # a row the current schedule no longer produces stands in for a cycle.
  test "a semimonthly bill on close days keeps both occurrences" do
    # On Aug 3 the 90-day horizon ends on Nov 1, between the two days, so the
    # Nov 5 occurrence is added by a later run, with Nov 1 already there.
    travel_to Date.new(2026, 8, 3) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "semimonthly", day_of_month: "1", second_day_of_month: "5")
      @series.save!
      assert_includes @series.recurring_occurrences.reload.pluck(:due_on), Date.new(2026, 11, 1)
      assert_not_includes @series.recurring_occurrences.pluck(:due_on), Date.new(2026, 11, 5)
    end

    travel_to Date.new(2026, 8, 8) do
      Generator.new(@series).generate!

      dues = @series.recurring_occurrences.reload.pluck(:due_on)
      [ Date.new(2026, 9, 1), Date.new(2026, 9, 5), Date.new(2026, 11, 1), Date.new(2026, 11, 5) ].each do |date|
        assert_includes dues, date
      end
      assert_equal 0, Generator.new(@series).generate!, "steady state inserts nothing"
    end
  end

  # A kept row stands in for one occurrence, the nearest, not for every
  # occurrence within half a cycle: semimonthly days a few days apart are both
  # within reach of it.
  test "a due-day shift on a close semimonthly bill keeps the other day" do
    travel_to Date.new(2026, 10, 3) do
      RecurringTransaction::FrequencyPreset.apply(@series, preset: "semimonthly", day_of_month: "1", second_day_of_month: "5")
      @series.save!
      paid = @series.recurring_occurrences.reload.find_by!(due_on: Date.new(2026, 10, 1))
      paid.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created")
      assert_includes @series.recurring_occurrences.pluck(:due_on), Date.new(2026, 10, 5)

      RecurringTransaction::FrequencyPreset.apply(@series, preset: "semimonthly", day_of_month: "2", second_day_of_month: "5")
      @series.save!

      dues = @series.recurring_occurrences.reload.pluck(:due_on)
      assert_not_includes dues, Date.new(2026, 10, 2), "the kept Oct 1 row already is this occurrence"
      assert_includes dues, Date.new(2026, 10, 5), "the unchanged second day is rebuilt"
      assert_includes dues, Date.new(2026, 11, 2)
      assert_includes dues, Date.new(2026, 11, 5)
    end
  end

  # #4300 is reached by a hand edit of the due day too, and the reporter moved
  # it twice (27, then 24, then 22). The second edit must not resurrect a row
  # beside the paid cycle either, and the later cycles follow the latest day.
  # update! of the column is the API's edit; the bill form's is in the
  # controller test.
  test "two successive due-day edits keep a paid cycle to one occurrence" do
    travel_to Date.new(2026, 10, 28) do
      @series.update!(expected_day_of_month: 27)
      paid = @series.recurring_occurrences.reload.find_by!(due_on: Date.new(2026, 10, 27))
      paid.allocations.create!(allocated_amount: 5, currency: "USD", source: "user_created")
      october = Date.new(2026, 10, 1)..Date.new(2026, 10, 31)

      @series.update!(expected_day_of_month: 24)
      assert_equal [ paid.id ], @series.recurring_occurrences.reload.where(due_on: october).pluck(:id),
                   "the first edit adds no Oct 24 row beside the paid Oct 27 one"
      assert_includes @series.recurring_occurrences.pluck(:due_on), Date.new(2026, 11, 24)

      @series.update!(expected_day_of_month: 22)
      assert_equal [ paid.id ], @series.recurring_occurrences.reload.where(due_on: october).pluck(:id),
                   "the second edit adds no Oct 22 or Oct 24 row beside the paid Oct 27 one"
      dues = @series.recurring_occurrences.pluck(:due_on)
      assert_includes dues, Date.new(2026, 11, 22)
      assert_not_includes dues, Date.new(2026, 11, 24), "the first edit's future rows are rebuilt on the new day"
    end
  end

  test "two successive due-day edits keep an unpaid past-due cycle to one occurrence" do
    travel_to Date.new(2026, 10, 28) do
      @series.update!(expected_day_of_month: 27)
      past_due = @series.recurring_occurrences.reload.find_by!(due_on: Date.new(2026, 10, 27))
      october = Date.new(2026, 10, 1)..Date.new(2026, 10, 31)

      @series.update!(expected_day_of_month: 24)
      @series.update!(expected_day_of_month: 22)

      assert_equal [ past_due.id ], @series.recurring_occurrences.reload.where(due_on: october).pluck(:id)
      dues = @series.recurring_occurrences.pluck(:due_on)
      assert_includes dues, Date.new(2026, 11, 22)
      assert_not_includes dues, Date.new(2026, 11, 24)
    end
  end
end
