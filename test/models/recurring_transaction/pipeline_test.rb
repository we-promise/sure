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

      result = Pipeline.new(@family).run!

      refute result.locked?
      assert_operator result.patterns_count, :>=, 1

      series = @family.recurring_transactions.find_by(name: "CITY POWER")
      assert series.present?, "detection must create the series"
      assert series.suggested?, "unclaimed detections land as suggestions"
      # Suggested series are not active, so nothing materializes until the
      # user confirms -- the pipeline must not conjure occurrences for them.
      assert_equal 0, series.recurring_occurrences.count
    end
  end

  test "run! materializes active series and backfills history exactly once" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY WATER", amount: 80, day_offset: -1)
      3.times do |i|
        create_entry(amount: 80, date: Date.new(2026, 8, 9) - (i + 1).months, name: "CITY WATER")
      end

      # The upgraded-instance signature: series exist, occurrences never
      # materialized (creation auto-generates, so wipe them).
      RecurringOccurrence.where(recurring_transaction: series).delete_all
      assert @family.recurring_occurrences.none?

      Pipeline.new(@family).run!

      historical = series.recurring_occurrences.where("due_on < ?", Date.new(2026, 8, 1))
      assert_operator historical.paid.count, :>=, 1,
        "first run reconstructs paid history from real entries"

      # Second run: not first-run any more; nothing new appears.
      before_ids = series.recurring_occurrences.order(:id).pluck(:id)
      Pipeline.new(@family).run!
      assert_equal before_ids, series.recurring_occurrences.order(:id).pluck(:id)
    end
  end

  test "an existing occurrence suppresses the first-run backfill" do
    travel_to Date.new(2026, 8, 10) do
      series = create_series(name: "CITY GAS", amount: 55, day_offset: -1)
      create_entry(amount: 55, date: Date.new(2026, 6, 9), name: "CITY GAS")

      assert @family.recurring_occurrences.any?,
        "series creation should have materialized occurrences"

      Pipeline.new(@family).run!

      assert_equal 0,
        series.recurring_occurrences.where("due_on < ?", Date.new(2026, 7, 1)).count,
        "a family that already has occurrences must not be backfilled"
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

    assert result.locked?
    assert_equal 0, result.patterns_count
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
