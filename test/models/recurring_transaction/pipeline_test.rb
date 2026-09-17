require "test_helper"

class RecurringTransaction::PipelineTest < ActiveSupport::TestCase
  Pipeline = RecurringTransaction::Pipeline

  def setup
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
  end

  test "run! detects, materializes and matches in one pass" do
    travel_to Date.new(2026, 8, 10) do
      # Three consistent monthly charges: enough for the identifier.
      3.times do |i|
        create_entry(amount: 42.50, date: Date.new(2026, 8, 9) - i.months, name: "CITY POWER")
      end

      patterns_count = Pipeline.new(@family).run!

      assert_operator patterns_count, :>=, 1

      series = @family.recurring_transactions.find_by(name: "CITY POWER")
      assert series.present?, "detection must create the series"
      assert series.suggested?, "unclaimed detections land as suggestions"
      # Suggested series are not active, so nothing materializes until the
      # user confirms -- the pipeline must not conjure occurrences for them.
      assert_equal 0, series.recurring_occurrences.count
    end
  end

  test "run! with backfill reconstructs history and is idempotent" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY WATER", amount: 80, day_offset: -1)
      3.times do |i|
        create_entry(amount: 80, date: Date.new(2026, 8, 9) - (i + 1).months, name: "CITY WATER")
      end

      # The upgraded-instance shape: series exist, occurrences never
      # materialized (creation auto-generates, so wipe them).
      RecurringOccurrence.where(recurring_transaction: series).delete_all
      assert @family.recurring_occurrences.none?

      Pipeline.new(@family).run!(backfill: true)

      historical = series.recurring_occurrences.where("due_on < ?", Date.new(2026, 8, 1))
      assert_operator historical.paid.count, :>=, 1,
        "the backfill reconstructs paid history from real entries"

      # Backfilling again reconstructs nothing twice.
      before_ids = series.recurring_occurrences.order(:id).pluck(:id)
      Pipeline.new(@family).run!(backfill: true)
      assert_equal before_ids, series.recurring_occurrences.order(:id).pluck(:id)
    end
  end

  test "run! without backfill never reconstructs history" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY GAS", amount: 55, day_offset: -1)
      create_entry(amount: 55, date: Date.new(2026, 6, 9), name: "CITY GAS")

      # Even in the upgraded-instance shape (zero occurrences), a plain run
      # must not backfill: background syncs keep their old cost profile.
      RecurringOccurrence.where(recurring_transaction: series).delete_all
      assert @family.recurring_occurrences.none?

      Pipeline.new(@family).run!

      assert_equal 0,
        series.recurring_occurrences.where("due_on < ?", Date.new(2026, 7, 1)).count,
        "only an explicit backfill request reconstructs history"
    end
  end

  test "run_with_lock! refuses to stack on a held family lock" do
    key = Pipeline.advisory_lock_key(@family.id)
    # Transactional tests hand every checkout the same shared fixture
    # connection, and a session can always re-take its own advisory lock, so
    # holding the lock needs a genuinely separate PG session.
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    other = PG.connect({
      dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username], password: config[:password]
    }.compact)
    other.exec("SELECT pg_advisory_lock(#{key})")

    result = Pipeline.new(@family).run_with_lock!

    assert_nil result, "a held lock reports nil rather than running"
  ensure
    other&.close
  end

  private

    def create_series(amount:, day_offset:, name: nil, merchant: nil)
      due = Date.current + day_offset

      @family.recurring_transactions.create!(
        name: name,
        merchant: merchant,
        account: @account,
        amount: amount,
        currency: "USD",
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: true
      )
    end

    def create_entry(amount:, date:, name:)
      @account.entries.create!(
        date: date,
        amount: amount,
        currency: "USD",
        name: name,
        entryable: Transaction.new
      )
    end
end
