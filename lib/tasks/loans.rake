namespace :loans do
  desc "Verify every C1-C16 contract row maps to an existing test"
  task verify_contract_coverage: :environment do
    require "yaml"

    contract_path = Rails.root.join("docs/loans/calculation-contract.md")
    manifest_path = Rails.root.join("config/loan_contract_tests.yml")
    rows = File.readlines(contract_path).filter_map do |line|
      match = line.match(/^\| C(\d+) \|.*?\| `([^`]+)`/)
      next unless match

      [ "C#{match[1]}", match[2] ]
    end.to_h
    manifest = YAML.load_file(manifest_path)
    expected_ids = (1..16).map { |id| "C#{id}" }

    contract_ids = rows.keys.sort_by { |id| id.delete_prefix("C").to_i }
    manifest_ids = manifest.keys.sort_by { |id| id.delete_prefix("C").to_i }
    abort "contract rows must cover C1-C16" unless contract_ids == expected_ids
    abort "contract manifest must cover C1-C16" unless manifest_ids == expected_ids

    manifest.each do |id, entry|
      file_path = Rails.root.join(entry.fetch("file"))
      abort "#{id}: missing #{file_path}" unless file_path.file?

      source = File.read(file_path)
      class_name = entry.fetch("class")
      abort "#{id}: #{class_name} is not declared in #{file_path}" unless source.include?("class #{class_name} <")
      entry.fetch("tests").each do |test_name|
        next if source.include?(%(test "#{test_name}"))

        abort "#{id}: missing test #{test_name.inspect} in #{file_path}"
      end
    end

    puts "Verified #{manifest.length} contract rows against existing tests"
  end

  desc "Benchmark production-shaped daily accrual and report p95/p99 latency"
  task amortization_benchmark: :environment do
    require "benchmark"

    loan_count = [ (ENV["LOAN_COUNT"].presence || "100").to_i, 1 ].max
    history_months = [ (ENV["HISTORY_MONTHS"].presence || "360").to_i, 1 ].max
    offset_frequency = [ (ENV["OFFSET_FREQUENCY_DAYS"].presence || "30").to_i, 1 ].max
    max_p95_ms = (ENV["MAX_P95_MS"].presence || "100").to_f
    max_p99_ms = (ENV["MAX_P99_MS"].presence || "150").to_f
    payment_dates = Array.new(history_months + 1) { |index| Date.new(2024, 1, 1) >> index }
    payment_amount = ->(rate:, balance:, remaining_payments:, **_) {
      monthly_rate = BigDecimal(rate.to_s) / 100 / 12
      next (balance / remaining_payments).round(2) if monthly_rate.zero?

      factor = (1 + monthly_rate) ** remaining_payments
      (balance * monthly_rate * factor / (factor - 1)).round(2)
    }

    samples = loan_count.times.map do
      Benchmark.realtime do
        Loan::Simulator.new(
          starting_balance: BigDecimal("500000"),
          starting_balance_as_of: payment_dates.first,
          accrual_start_date: payment_dates.first,
          payment_schedule: payment_dates.drop(1),
          accrual_rate_for: ->(_date) { BigDecimal("6") },
          re_amortisation_events: ->(_from_date, _to_date) { [] },
          payment_strategy: :reamortize,
          payment_amount_for: payment_amount,
          currency_precision: 2,
          daily_accrual: true,
          offset_for: ->(from_date, _to_date) {
            (1...offset_frequency).map do |day|
              { date: from_date + day, amount: BigDecimal("100000") }
            end
          }
        ).run
      end * 1000
    end.sort

    percentile = ->(values, fraction) { values[[ (values.length * fraction).ceil - 1, 0 ].max] }
    p95_ms = percentile.call(samples, 0.95)
    p99_ms = percentile.call(samples, 0.99)
    puts format(
      "loan_count=%d history_months=%d offset_frequency_days=%d p95_ms=%.3f p99_ms=%.3f max_p95_ms=%.3f max_p99_ms=%.3f",
      loan_count, history_months, offset_frequency, p95_ms, p99_ms, max_p95_ms, max_p99_ms
    )
    abort "amortization p95 SLO exceeded" if p95_ms > max_p95_ms
    abort "amortization p99 SLO exceeded" if p99_ms > max_p99_ms
  end

  desc "Compare monthly and daily loan calculations for a bounded sample"
  task :amortization_variance, [ :limit, :output ] => :environment do |_, args|
    require "csv"

    limit = [ (args[:limit].presence || ENV["LIMIT"].presence || "100").to_i, 1 ].max
    output = args[:output].presence || ENV["OUTPUT"].presence
    rows = []
    Loan.where.not(term_months: nil).order(:id).limit(limit).find_each do |loan|
      monthly = loan.amortization_schedule.simulation
      daily = loan.amortization_schedule.simulation(daily_accrual: true)
      rows << {
        loan_id: loan.id,
        monthly_interest: monthly.total_interest.to_s("F"),
        daily_interest: daily.total_interest.to_s("F"),
        interest_delta: (daily.total_interest - monthly.total_interest).to_s("F"),
        monthly_converged: monthly.converged?,
        daily_converged: daily.converged?
      }
    end
    columns = rows.first&.keys || %i[loan_id monthly_interest daily_interest interest_delta monthly_converged daily_converged]
    csv = CSV.generate { |document| document << columns; rows.each { |row| document << columns.map { |column| row[column] } } }
    output ? File.write(output, csv) : puts(csv)
  end

  desc "Rebuild loan amortization schedules in bounded, rate-limited batches"
  task :rebuild_schedules, [ :batch_size, :limit, :sleep ] => :environment do |_, args|
    raw_batch_size = args[:batch_size].presence || ENV["BATCH_SIZE"].presence || "100"
    batch_size = [ raw_batch_size.to_i, 1 ].max
    limit = args[:limit].presence&.to_i
    pause = args[:sleep].presence&.to_f || 0.0
    rebuilt = 0

    scope = Loan.where.not(term_months: nil).order(:id)
    scope = scope.limit(limit) if limit&.positive?

    puts "Rebuilding loan schedules (batch_size=#{batch_size}, limit=#{limit || 'all'}, sleep=#{pause}s)"
    scope.find_in_batches(batch_size: batch_size) do |loans|
      loans.each do |loan|
        loan.rebuild_amortization_schedule
        rebuilt += 1
        puts "Rebuilt #{rebuilt}: #{loan.id}"
        sleep(pause) if pause.positive?
      end
    end

    puts "Completed loan schedule rebuild: #{rebuilt} loans"
  end
end
