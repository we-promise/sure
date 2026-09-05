require "test_helper"

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

  test "rebuild task rebuilds a bounded batch and is idempotent" do
    loan = loans(:characterization_fixed)
    loan.rebuild_amortization_schedule
    first = loan.amortizations.ordered.map { |row| row.slice(:payment_number, :payment_amount, :ending_balance) }

    capture_io { Rake::Task["loans:rebuild_schedules"].invoke("1", "1") }

    second = loan.reload.amortizations.ordered.map { |row| row.slice(:payment_number, :payment_amount, :ending_balance) }
    assert_equal first, second, "a rebuild must be idempotent"
    assert_predicate loan.amortizations.count, :positive?
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
