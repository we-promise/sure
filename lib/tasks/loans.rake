namespace :loans do
  # Resolve a task parameter from its positional rake argument, then from the
  # environment, then a default.
  #
  # Every loans:* parameter goes through this. It exists because they did not:
  # `rebuild_schedules` read BATCH_SIZE from the environment but `sleep` from
  # args only, so the rollout command documented in
  # docs/loans/release-evidence.md -- `BATCH_SIZE=100 SLEEP=0.25` -- silently
  # ran with no rate limiting at all (#38). The inconsistency was the defect;
  # one resolver removes the class of bug rather than the instance.
  loan_task_option = ->(args, name, default = nil) do
    args[name].presence || ENV[name.to_s.upcase].presence || default
  end

  desc "Verify every C1-C16 contract row maps to an existing test"
  task verify_contract_coverage: :environment do
    require "yaml"

    contract_path = Rails.root.join("docs/loans/calculation-contract.md")
    manifest_path = Rails.root.join("config/loan_contract_tests.yml")
    parsed_rows = File.readlines(contract_path).filter_map do |line|
      match = line.match(/^\| C(\d+) \|.*?\| `([^`]+)`/)
      next unless match

      [ "C#{match[1]}", match[2] ]
    end
    # Reject duplicates BEFORE collapsing. `to_h` keeps the last occurrence, so
    # a contract carrying C7 twice would silently discard one -- and if the
    # surviving row happened to match the manifest, a wrong duplicate would
    # pass this gate unseen.
    duplicate_ids = parsed_rows.map(&:first).tally.select { |_id, count| count > 1 }.keys.sort
    abort "duplicate contract rows: #{duplicate_ids.join(', ')}" if duplicate_ids.any?

    rows = parsed_rows.to_h
    manifest = YAML.load_file(manifest_path)
    expected_ids = (1..16).map { |id| "C#{id}" }

    contract_ids = rows.keys.sort_by { |id| id.delete_prefix("C").to_i }
    manifest_ids = manifest.keys.sort_by { |id| id.delete_prefix("C").to_i }
    abort "contract rows must cover C1-C16" unless contract_ids == expected_ids
    abort "contract manifest must cover C1-C16" unless manifest_ids == expected_ids

    # The contract document's test-name column must agree with the manifest.
    #
    # This check is why C16 could name Loan::OffsetResolverTest -- a class that
    # does not exist anywhere in the repository -- while this gate passed: the
    # names parsed out of the contract were collected into `rows` and then used
    # only to confirm the row IDs ran C1..C16. They were never compared to
    # anything. G1 requires each row to name a test that exists.
    rows.each do |id, documented_class|
      manifest_class = manifest.fetch(id).fetch("class")
      next if documented_class == manifest_class

      abort "#{id}: contract names #{documented_class}, manifest names #{manifest_class}"
    end

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
  task :amortization_benchmark, [ :loan_count, :history_months, :offset_frequency_days, :max_p95_ms, :max_p99_ms ] => :environment do |_, args|
    require "benchmark"

    loan_count = [ loan_task_option.call(args, :loan_count, "100").to_i, 1 ].max
    history_months = [ loan_task_option.call(args, :history_months, "360").to_i, 1 ].max
    offset_frequency = [ loan_task_option.call(args, :offset_frequency_days, "30").to_i, 1 ].max
    max_p95_ms = loan_task_option.call(args, :max_p95_ms, "100").to_f
    max_p99_ms = loan_task_option.call(args, :max_p99_ms, "150").to_f
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

    limit = [ loan_task_option.call(args, :limit, "100").to_i, 1 ].max
    output = loan_task_option.call(args, :output)
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
    batch_size = [ loan_task_option.call(args, :batch_size, "100").to_i, 1 ].max
    limit = loan_task_option.call(args, :limit)&.to_i
    pause = loan_task_option.call(args, :sleep, "0").to_f
    rebuilt = 0

    scope = Loan.where.not(term_months: nil).order(:id)
    scope = scope.limit(limit) if limit&.positive?

    # Print the EFFECTIVE options, not the requested ones, so a rehearsal
    # transcript records what actually ran rather than what was typed.
    puts "Rebuilding loan schedules (batch_size=#{batch_size}, limit=#{limit || 'all'}, sleep=#{pause}s)"
    puts "WARNING: no rate limit -- pass SLEEP or the third argument to throttle" unless pause.positive?
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
