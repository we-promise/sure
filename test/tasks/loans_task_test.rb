require "test_helper"
require "benchmark"

load Rails.root.join("lib/tasks/loans.rake")

# Every task in lib/tasks/loans.rake is invoked here at least once.
#
# This file exists because it did not: `loans:amortization_variance` shipped
# calling `Loan::AmortizationSchedule#simulation`, a method that was not on the
# branch, and raised NoMethodError with nothing to catch it (#37). A rake task
# with no test is a script nobody has run.
class LoansTaskTest < ActiveSupport::TestCase
  setup do
    %w[
      loans:verify_contract_coverage
      loans:amortization_benchmark
      loans:amortization_variance
      loans:rebuild_schedules
      loans:schedule_version_status
    ].each do |name|
      Rake::Task[name].clear_prerequisites
      Rake::Task[name].reenable
    end
  end

  test "contract coverage task verifies every C1-C16 row against an existing test" do
    assert_nothing_raised { Rake::Task["loans:verify_contract_coverage"].invoke }
  end

  test "benchmark task reports p95 and p99 for the configured workload" do
    output = capture_io_with_env(
      "LOAN_COUNT" => "2",
      "HISTORY_MONTHS" => "12",
      "OFFSET_FREQUENCY_DAYS" => "5",
      "MAX_P95_MS" => "600000",
      "MAX_P99_MS" => "600000"
    ) { Rake::Task["loans:amortization_benchmark"].invoke }

    assert_match(/loan_count=2 history_months=12 offset_frequency_days=5/, output)
    assert_match(/p95_ms=\d+\.\d+ p99_ms=\d+\.\d+/, output)
  end

  test "benchmark task aborts when the p95 SLO is exceeded" do
    error = assert_raises(SystemExit) do
      capture_io_with_env(
        "LOAN_COUNT" => "2", "HISTORY_MONTHS" => "12",
        "OFFSET_FREQUENCY_DAYS" => "5", "MAX_P95_MS" => "0", "MAX_P99_MS" => "0"
      ) { Rake::Task["loans:amortization_benchmark"].invoke }
    end

    assert_not_predicate error, :success?
  end

  test "variance task writes a non-mutating monthly versus daily report" do
    output = Rails.root.join("tmp", "loan-variance-test.csv")
    FileUtils.rm_f(output)
    before = LoanAmortization.count

    Rake::Task["loans:amortization_variance"].invoke("1", output.to_s)

    rows = CSV.read(output, headers: true)
    assert_equal 1, rows.length
    assert_equal(
      %w[loan_id monthly_interest daily_interest interest_delta monthly_converged daily_converged],
      rows.headers
    )
    assert_equal "true", rows.first["monthly_converged"]
    assert_equal "true", rows.first["daily_converged"]

    row = rows.first
    assert_equal(
      (BigDecimal(row["daily_interest"]) - BigDecimal(row["monthly_interest"])),
      BigDecimal(row["interest_delta"]),
      "interest_delta must be daily minus monthly"
    )
    assert_equal before, LoanAmortization.count, "the variance report must not write schedule rows"
  ensure
    FileUtils.rm_f(output)
  end

  # The report exists to evidence a monthly-to-daily transition, so its two
  # columns are the two accrual modes and neither can be pinned to "whatever
  # production ships" -- that would make the report compare a mode against
  # itself once the transition landed, reporting every delta as zero exactly
  # when the release it evidences was being prepared.
  #
  # What must stay true is that the report is not describing a calculation
  # nobody runs: the column matching SCHEDULE_DAILY_ACCRUAL has to equal what
  # the persisted schedule actually produces. Asserted against the constant so
  # this holds whichever way it is set.
  test "the variance column matching the shipped accrual mode equals what production persists" do
    output = Rails.root.join("tmp", "loan-variance-parity.csv")
    FileUtils.rm_f(output)

    Rake::Task["loans:amortization_variance"].invoke("1", output.to_s)
    row = CSV.read(output, headers: true).first
    loan = Loan.find(row["loan_id"])

    shipped_column =
      Loan::AmortizationSchedule::SCHEDULE_DAILY_ACCRUAL ? "daily_interest" : "monthly_interest"

    # Compare against the PERSISTED rows, not a fresh
    # `amortization_schedule.payments`. Recomputing here would run the same code
    # the report runs, so the assertion would hold even if persistence or row
    # mapping dropped the figure on the way to the table users actually read.
    loan.rebuild_amortization_schedule
    assert_predicate loan.amortizations.count, :positive?,
      "test setup must persist schedule rows, or the comparison below is vacuous"

    assert_equal(
      loan.amortizations.sum(:interest_payment),
      BigDecimal(row[shipped_column]),
      "the report's #{shipped_column} column must equal the persisted LoanAmortization rows"
    )
  ensure
    FileUtils.rm_f(output)
  end

  # The other column is the comparison side. It must be the OTHER mode, not a
  # second copy of the shipped one -- the defect that made this report useless
  # the moment SCHEDULE_DAILY_ACCRUAL flipped.
  test "the variance report's two columns are genuinely different accrual modes" do
    output = Rails.root.join("tmp", "loan-variance-modes.csv")
    FileUtils.rm_f(output)

    Rake::Task["loans:amortization_variance"].invoke("1", output.to_s)
    row = CSV.read(output, headers: true).first
    loan = Loan.find(row["loan_id"])

    monthly = loan.amortization_schedule.simulation(daily_accrual: false).total_interest
    daily = loan.amortization_schedule.simulation(daily_accrual: true).total_interest

    # Without this, a loan whose two modes happen to coincide (any 0% loan, for
    # one) would let a report that wrote a single mode into both columns pass
    # the assertions below -- the exact defect this test exists to catch.
    assert_not_equal monthly, daily,
      "test setup must select a loan whose accrual modes genuinely differ"

    assert_equal monthly, BigDecimal(row["monthly_interest"]),
      "the monthly column must be an explicitly monthly run"
    assert_equal daily, BigDecimal(row["daily_interest"]),
      "the daily column must be an explicitly daily run"
    assert_not_equal row["monthly_interest"], row["daily_interest"],
      "the two columns must not carry the same figure"
  ensure
    FileUtils.rm_f(output)
  end

  # Rebuilds the whole population rather than a bounded slice, so the loan
  # under test is definitely reached: `limit` selects by id order, which need
  # not include any particular fixture.
  #
  # Also deletes the rows first, so the run has something stale to rebuild.
  # The earlier version pre-built the schedule and then asserted it was
  # unchanged, which passes whether or not the task selects stale loans at all.
  test "rebuild task rebuilds a stale schedule and is idempotent" do
    loan = loans(:characterization_fixed)
    loan.rebuild_amortization_schedule
    expected = loan.amortizations.ordered.map { |row| row.slice(:payment_number, :payment_amount, :ending_balance) }
    assert_predicate expected.length, :positive?

    loan.amortizations.delete_all
    assert_empty loan.reload.amortizations, "the run must have something stale to rebuild"

    capture_io { Rake::Task["loans:rebuild_schedules"].invoke }
    rebuilt = loan.reload.amortizations.ordered.map { |row| row.slice(:payment_number, :payment_amount, :ending_balance) }
    assert_equal expected, rebuilt, "the task must rebuild a missing schedule"

    Rake::Task["loans:rebuild_schedules"].reenable
    capture_io { Rake::Task["loans:rebuild_schedules"].invoke }
    again = loan.reload.amortizations.ordered.map { |row| row.slice(:payment_number, :payment_amount, :ending_balance) }
    assert_equal expected, again, "a second run must be idempotent"
  end

  # --- deploy monitoring: the runbook's "stale schedules" signal -----------
  #
  # docs/loans/release-evidence.md tells an operator to watch stale schedules
  # trending to zero during a prebuild. Until this task existed the signal had
  # no implementation, and `algorithm_version` -- the column added to make it
  # queryable -- was written and validated but never read by anything.

  # A FALSE-CLEAN DEPLOY SIGNAL is worse than a red one, and #78 created the
  # conditions for exactly one.
  #
  # `rebuild_schedules` walks `Loan.where.not(term_months: nil)` -- no rate-type
  # filter -- so it builds an adjustable loan's schedule as soon as #14 makes
  # that type amortizable. The status task narrowed its "awaiting a first
  # build" query with a hardcoded %w[fixed variable], so it did not count that
  # loan, could report stale=0, and would exit 0 while the loan was still
  # unbuilt. The runbook treats that exit code as the prebuild completion
  # decision.
  #
  # Both now derive from Loan::AMORTIZABLE_RATE_TYPES. This test fails if they
  # are ever allowed to drift apart again.
  test "an unbuilt adjustable loan is counted as awaiting a first build" do
    # The estate must be clean FIRST. Without this the task exits non-zero
    # because of unrelated fixture loans, and the assertion below passes
    # whether or not the adjustable loan was counted -- which is exactly what
    # the first version of this test did.
    capture_io { Rake::Task["loans:rebuild_schedules"].invoke }
    Rake::Task["loans:rebuild_schedules"].reenable

    baseline, baseline_exit, _ = capture_output_and_exit { Rake::Task["loans:schedule_version_status"].invoke }
    assert_nil baseline_exit, "the estate must start clean, or the signal under test is masked"
    assert_match(/awaiting_first_build=0/, baseline)
    Rake::Task["loans:schedule_version_status"].reenable

    loan = loans(:characterization_fixed)
    loan.update!(rate_type: "adjustable")
    loan.amortizations.delete_all
    assert_predicate loan.reload.amortization_schedule, :amortizable?,
      "the fixture must be amortizable as an adjustable loan, or this proves nothing"

    output, exit_error, _stderr = capture_output_and_exit { Rake::Task["loans:schedule_version_status"].invoke }

    assert_failed_exit exit_error,
      "an adjustable loan with no rows is unbuilt; exiting 0 here is a false-clean deploy signal"
    assert_match(/awaiting_first_build=1/, output,
      "the unbuilt adjustable loan must be counted, not merely make some other loan stale")

    Rake::Task["loans:schedule_version_status"].reenable
    Rake::Task["loans:rebuild_schedules"].reenable
    capture_io { Rake::Task["loans:rebuild_schedules"].invoke }

    after, exit_error_after, _ = capture_output_and_exit { Rake::Task["loans:schedule_version_status"].invoke }

    assert_nil exit_error_after, "after the rebuild the same loan must report clean"
    assert_match(/awaiting_first_build=0/, after)
  end

  test "schedule version status reports loans left on an older algorithm version" do
    current = Loan::AmortizationSchedule::ALGORITHM_VERSION
    loan = loans(:characterization_fixed)
    loan.rebuild_amortization_schedule
    assert_predicate loan.amortizations.count, :positive?

    # A loan stranded on the previous version is exactly what a version bump
    # creates and what the prebuild has to clear.
    loan.amortizations.update_all(algorithm_version: current - 1)

    output, exit_error, stderr = capture_output_and_exit { Rake::Task["loans:schedule_version_status"].invoke }

    assert_failed_exit exit_error, "staleness must exit non-zero so this can gate a deploy step"
    assert_match(/version #{current - 1}: \d+ loans \(STALE\)/, output,
      "the older version must be reported as stale, and named")
    assert_match(/stale=[1-9]/, output)
    assert_match(/loans:rebuild_schedules/, stderr,
      "the failure message must tell an operator what to run, and must be capturable")
  end

  test "schedule version status counts a loan with no rows as stale, not as clean" do
    loan = loans(:characterization_fixed)
    loan.rebuild_amortization_schedule
    loan.amortizations.delete_all

    output, exit_error = capture_output_and_exit { Rake::Task["loans:schedule_version_status"].invoke }

    # A loan the rebuild task would still have to visit must not read as clean
    # merely because it has no rows to be the wrong version -- counting only
    # rows that exist would report an empty estate as fully rebuilt.
    assert_failed_exit exit_error, "a loan with no schedule must not report as clean"
    assert_match(/awaiting_first_build=[1-9]/, output)
  end

  # Regression: a loan with a term but no rate is in the rebuild scope (SQL can
  # only filter on term_months) but is never amortizable, so
  # `rebuild_amortization_schedule_locked!` deletes its rows and returns. An
  # earlier version of this task counted every row-less loan as stale, so such a
  # loan sat in the count permanently and the task could never exit 0 -- making
  # the one signal that answers "is the prebuild finished?" permanently red.
  test "schedule version status does not count a non-amortizable loan as stale forever" do
    non_amortizable = Account.create!(
      family: families(:dylan_family), name: "No rate #{SecureRandom.hex(4)}",
      balance: 1000, currency: "USD",
      accountable: Loan.new(subtype: "other", term_months: 12, rate_type: "fixed", start_date: Date.current)
    ).loan

    assert_not non_amortizable.amortization_schedule.amortizable?,
      "test setup must produce a loan the rebuild will never give rows to"
    assert Loan.where.not(term_months: nil).exists?(id: non_amortizable.id),
      "test setup must produce a loan inside the rebuild scope, or it proves nothing"

    capture_io { Rake::Task["loans:rebuild_schedules"].invoke }
    assert_empty non_amortizable.reload.amortizations,
      "the rebuild leaves this loan with no rows, which is the condition under test"

    Rake::Task["loans:schedule_version_status"].reenable
    output, exit_error = capture_output_and_exit { Rake::Task["loans:schedule_version_status"].invoke }

    assert_match(/not_amortizable=[1-9]/, output,
      "a loan the rebuild will never populate must be reported as such, not as stale")
    refute_match(/awaiting_first_build=[1-9]/, output,
      "it must not be counted as awaiting a build the rebuild will never perform")
    assert_nil exit_error,
      "with every amortizable schedule current, the task must exit 0 -- otherwise the prebuild " \
      "can never be declared finished"
  end

  # --- #38: every documented parameter must actually be read ---------------

  test "rebuild task honours SLEEP from the environment" do
    output = capture_io_with_env("SLEEP" => "0.25", "LIMIT" => "1") do
      Rake::Task["loans:rebuild_schedules"].invoke
    end

    assert_match(/sleep=0\.25s/, output,
      "SLEEP was ignored -- the documented rollout command would run unthrottled (#38)")
    assert_no_match(/WARNING: no rate limit/, output)
  end

  # The test above proves SLEEP is RESOLVED. It cannot prove it is APPLIED:
  # with one loan it only reads the logged value, so deleting `sleep(pause)`
  # from the task would leave it green. Rate limiting is the behaviour #38
  # exists to protect.
  #
  # Timed rather than stubbed: a rake task block's `self` is `main`, so `sleep`
  # is Kernel#sleep on the top-level object and cannot be intercepted without
  # stubbing it for every test in the process. Timing asserts the real
  # behaviour with no such blast radius.
  test "rebuild task actually pauses between the loans it rebuilds" do
    assert_operator Loan.where.not(term_months: nil).count, :>=, 2,
      "this test needs at least two loans for a pause to occur between any"

    pause = 0.2
    elapsed = Benchmark.realtime do
      capture_io_with_env("SLEEP" => pause.to_s, "LIMIT" => "2") do
        Rake::Task["loans:rebuild_schedules"].invoke
      end
    end

    # One interval, not two: with two loans there is a single gap between them.
    # Requiring 2 x pause would also fail if the task were improved to skip a
    # pointless final sleep after the last loan, which is a correct change.
    assert_operator elapsed, :>=, pause,
      "two rebuilt loans at SLEEP=#{pause} must take at least #{pause}s -- " \
      "deleting sleep(pause) from the task must fail this (#38)"
  end

  test "rebuild task warns when it is running with no rate limit" do
    output = capture_io_with_env("LIMIT" => "1") { Rake::Task["loans:rebuild_schedules"].invoke }

    assert_match(/sleep=0\.0s/, output)
    assert_match(/WARNING: no rate limit/, output,
      "an unthrottled production rebuild must be a visible choice, not a silent default")
  end

  test "rebuild task honours BATCH_SIZE and LIMIT from the environment" do
    output = capture_io_with_env("BATCH_SIZE" => "7", "LIMIT" => "1") do
      Rake::Task["loans:rebuild_schedules"].invoke
    end

    assert_match(/batch_size=7/, output)
    assert_match(/limit=1/, output)
  end

  test "positional arguments still win over the environment" do
    output = capture_io_with_env("BATCH_SIZE" => "7", "SLEEP" => "0.25") do
      Rake::Task["loans:rebuild_schedules"].invoke("3", "1", "0.5")
    end

    assert_match(/batch_size=3/, output)
    assert_match(/limit=1/, output)
    assert_match(/sleep=0\.5s/, output)
  end

  # The SLEEP defect was a disagreement between a runbook and the code it
  # documents. Assert they agree mechanically rather than by review.
  #
  # `loan_task_option` resolves ENV["FOO"] from the declared argument :foo, so
  # a task's argument list IS its set of supported environment variables. That
  # makes the check exact rather than a grep for the name.
  test "every environment variable in the release runbook is a declared task argument" do
    runbook = Rails.root.join("docs/loans/release-evidence.md").read

    invocations = runbook.scan(/^\s*(.*?)bin\/rails\s+(loans:\w+)(.*)$/)
    assert_operator invocations.length, :>, 0, "the runbook must document at least one loans:* command"

    seen = 0
    invocations.each do |before, task_name, after|
      declared = Rake::Task[task_name].arg_names.map(&:to_s)

      "#{before} #{after}".scan(/([A-Z][A-Z0-9_]*)=/).flatten.each do |var|
        next if var == "RAILS_ENV"

        seen += 1
        assert_includes declared, var.downcase,
          "#{task_name} is documented with #{var}, but declares no :#{var.downcase} argument, " \
          "so loan_task_option will never read it"
      end
    end

    assert_operator seen, :>, 0, "the runbook must pass at least one option to a loans:* command"
  end

  private

    # `abort` raises SystemExit, which makes minitest's capture_io discard what
    # was printed before it. This keeps both, so assertions can be made on the
    # output of a task that exits non-zero rather than only on the fact it did.
    #
    # Returns the exception, not a boolean: `exit(0)` also raises SystemExit, so
    # a boolean would let a task that stopped reporting failure keep passing
    # tests that assert it fails.
    def capture_output_and_exit
      out = StringIO.new
      err = StringIO.new
      original_out = $stdout
      original_err = $stderr
      # Both streams, because `abort` writes its message to $stderr. Capturing
      # only $stdout left the failure diagnostic -- the part that tells an
      # operator what to do -- uncapturable and leaking into the test run's own
      # output, which is the opposite of this helper's purpose.
      $stdout = out
      $stderr = err
      exit_error = nil
      begin
        yield
      rescue SystemExit => e
        exit_error = e
      end
      [ out.string, exit_error, err.string ]
    ensure
      $stdout = original_out
      $stderr = original_err
    end

    # Asserts a task both exited and exited unsuccessfully. `exit(0)` raises
    # SystemExit too, so asserting only that the task exited would pass for a
    # task that had stopped reporting failure at all.
    def assert_failed_exit(exit_error, message)
      assert exit_error, message
      assert_not exit_error.success?,
        "#{message} -- it exited, but with a success status, which no caller would treat as a failure"
    end

    def capture_io_with_env(env)
      original = env.keys.index_with { |key| ENV[key] }
      env.each { |key, value| ENV[key] = value }
      captured, = capture_io { yield }
      captured
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
