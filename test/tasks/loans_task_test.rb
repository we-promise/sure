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

  test "variance task reports the monthly column that production actually persists" do
    output = Rails.root.join("tmp", "loan-variance-parity.csv")
    FileUtils.rm_f(output)

    Rake::Task["loans:amortization_variance"].invoke("1", output.to_s)
    row = CSV.read(output, headers: true).first
    loan = Loan.find(row["loan_id"])

    assert_equal(
      loan.amortization_schedule.payments.sum { |payment| payment[:interest_payment] },
      BigDecimal(row["monthly_interest"]),
      "the report's monthly column must equal what Loan::AmortizationSchedule#payments produces"
    )
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

    assert_operator elapsed, :>=, pause * 2,
      "two rebuilt loans at SLEEP=#{pause} must take at least #{pause * 2}s -- " \
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

    def capture_io_with_env(env)
      original = env.keys.index_with { |key| ENV[key] }
      env.each { |key, value| ENV[key] = value }
      captured, = capture_io { yield }
      captured
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
