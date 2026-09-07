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

  # The population a rebuild walks. Shared so `schedule_version_status` reports
  # on exactly the loans `rebuild_schedules` would visit -- if these two drift
  # apart, the status task reports staleness the rebuild task will never clear,
  # and the "is the prebuild finished?" signal stops being answerable.
  #
  # Note this is a superset of *amortizable* loans: `term_months` is the widest
  # thing SQL can filter on, and `Loan::AmortizationSchedule#amortizable?` needs
  # the account and its opening valuation. The status task narrows it in Ruby.
  loan_rebuild_scope = -> { Loan.where.not(term_months: nil).order(:id) }

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

  desc "Prove each C1-C16 contract row's tests fail when that row's behaviour is broken"
  task :verify_contract_mutations, [ :rows ] => :environment do |_, args|
    require "yaml"
    require "open3"

    # Coverage (loans:verify_contract_coverage) proves a row NAMES a test that
    # exists. It cannot prove the test would notice if the behaviour changed --
    # a passing test that asserts nothing about the row satisfies it. G1 asks
    # for evidence, so this task produces it the only way that is not a claim:
    # break the behaviour in production code, and require the row's own tests
    # to go red. A row whose tests survive its mutation is reported as a
    # survivor and fails the task.
    manifest = YAML.load_file(Rails.root.join("config/loan_contract_tests.yml"))
    mutations = YAML.load_file(Rails.root.join("config/loan_contract_mutations.yml"))
    expected_ids = (1..16).map { |id| "C#{id}" }
    sorted = ->(ids) { ids.sort_by { |id| id.delete_prefix("C").to_i } }

    abort "mutation manifest must cover C1-C16" unless sorted.call(mutations.keys) == expected_ids

    # `rake "loans:verify_contract_mutations[C8,C10]"` delivers C8 as :rows and
    # C10 in extras, so reading :rows alone would silently run half the request
    # -- the same shape of bug #38 found in the rollout options.
    requested = [ loan_task_option.call(args, :rows), *args.extras ]
      .compact_blank
      .flat_map { |value| value.split(/[\s,]+/) }
      .map(&:upcase)
      .presence
    unknown = Array(requested) - expected_ids
    abort "unknown rows: #{unknown.join(', ')}" if unknown.any?
    ids = requested.presence || expected_ids

    # Mutating a file that already carries uncommitted edits would restore it
    # to the wrong content on the way out. Refuse rather than risk it.
    targets = ids.map { |id| mutations.fetch(id).fetch("file") }.uniq
    dirty = targets.select { |path| `git status --porcelain -- #{path}`.present? }
    abort "refusing to mutate files with uncommitted changes: #{dirty.join(', ')}" if dirty.any?

    run_tests = ->(entry) do
      pattern = entry.fetch("tests").map { |name| Regexp.escape(name) }.join("|")
      command = [ "bin/rails", "test", entry.fetch("file"), "-n", "/#{pattern}/" ]
      output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, *command, chdir: Rails.root.to_s)
      [ status.success?, output ]
    end

    survivors = []
    unprovable = []
    results = ids.map do |id|
      entry = manifest.fetch(id)
      mutation = mutations.fetch(id)
      path = Rails.root.join(mutation.fetch("file"))
      original = File.read(path)
      occurrences = original.scan(mutation.fetch("find")).length
      # A stale anchor mutates nothing, so the tests would pass and the row
      # would look like a survivor for the wrong reason. Fail loudly instead.
      abort "#{id}: anchor matches #{occurrences} times in #{mutation.fetch('file')} (expected exactly 1)" unless occurrences == 1

      baseline_passed, baseline_output = run_tests.call(entry)
      unless baseline_passed
        unprovable << id
        next { id: id, baseline: "FAIL", mutated: "-", output: baseline_output }
      end

      begin
        File.write(path, original.sub(mutation.fetch("find"), mutation.fetch("replace")))
        mutated_passed, mutated_output = run_tests.call(entry)
      ensure
        File.write(path, original)
      end

      survivors << id if mutated_passed
      { id: id, baseline: "pass", mutated: mutated_passed ? "SURVIVED" : "failed", output: mutated_output }
    end

    results.each do |result|
      puts format(
        "%-4s baseline=%-5s mutated=%-9s %s",
        result[:id], result[:baseline], result[:mutated], mutations.fetch(result[:id]).fetch("defect")
      )
    end

    abort "rows whose tests do not run clean before mutation: #{unprovable.join(', ')}" if unprovable.any?
    abort "rows whose tests survived their mutation: #{survivors.join(', ')}" if survivors.any?

    puts "Verified #{ids.length} contract rows: every row's tests pass unmutated and fail when its behaviour is broken"
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
      # Both modes are passed explicitly. Defaulting the monthly side to
      # SCHEDULE_DAILY_ACCRUAL made this report compare daily against daily
      # -- every delta zero -- the moment that constant flipped, i.e. exactly
      # when the release it exists to evidence was being prepared.
      monthly = loan.amortization_schedule.simulation(daily_accrual: false)
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

  # The runbook (docs/loans/release-evidence.md) tells an operator to watch
  # "stale schedules, trending to 0" during a version prebuild. Nothing measured
  # it. `Loan#schedule_current?` compares a SHA256 computed in Ruby per loan, so
  # counting stale loans that way is one query and one digest per loan -- fine
  # for a request serving one loan, useless as an estate-wide signal mid-deploy.
  #
  # `loan_amortizations.algorithm_version` was added to make exactly this
  # queryable and, until now, was written and validated but never read.
  #
  # Scope, stated because the difference matters when reading the output: this
  # reports VERSION staleness -- rows produced by an older calculation -- which
  # is what a version bump creates and what the prebuild clears. It does not
  # report INPUT staleness, a loan whose own rate or balance moved since its
  # rows were built at the current version. That is per-loan by nature and stays
  # with `schedule_current?`.
  desc "Report loan schedule staleness by algorithm version (deploy monitoring)"
  task schedule_version_status: :environment do
    current = Loan::AmortizationSchedule::ALGORITHM_VERSION

    # The same population `rebuild_schedules` walks, so "stale" counts what that
    # task would still have to do rather than a different set of loans.
    scope = loan_rebuild_scope.call
    total = scope.count

    # Version staleness is answered in one grouped query -- the reason
    # algorithm_version exists and the reason this is usable mid-deploy.
    versions = LoanAmortization
      .where(loan_id: scope.select(:id))
      .group(:algorithm_version)
      .distinct
      .count(:loan_id)

    with_rows = versions.values.sum
    behind = versions.reject { |version, _| version == current }.values.sum

    # Having no rows is NOT the same as being stale. `rebuild_schedules` deletes
    # rows and returns for a loan that is not amortizable (Loan
    # #rebuild_amortization_schedule_locked!), so a loan with a term but no
    # rate -- in this scope, never amortizable -- would sit in a naive
    # "missing" count forever and this task could never exit 0. That would make
    # the one signal answering "is the prebuild finished?" permanently red.
    #
    # `amortizable?` needs the account and its opening valuation, so it cannot
    # be expressed in SQL. It is resolved in Ruby for the loans that have no
    # rows and only those: in steady state that set is empty, and the one time
    # it is large is before a prebuild has run, when every loan is being
    # visited anyway.
    missing_ids = scope.where.missing(:amortizations).pluck(:id)
    awaiting, not_amortizable = Loan.where(id: missing_ids)
      .includes(account: :entries)
      .partition { |loan| loan.amortization_schedule.amortizable? }

    stale = behind + awaiting.length

    puts "algorithm_version=#{current}"
    puts "loans=#{total} with_rows=#{with_rows} awaiting_first_build=#{awaiting.length} " \
         "not_amortizable=#{not_amortizable.length}"
    versions.sort.each do |version, count|
      marker = version == current ? "current" : "STALE"
      puts "  version #{version}: #{count} loans (#{marker})"
    end
    puts "stale=#{stale} (#{behind} at an older version, #{awaiting.length} awaiting a first build)"

    # Non-zero exit on any staleness, so this can gate a deploy step or drive an
    # alert without the caller parsing stdout. A prebuild is finished when this
    # exits 0.
    if stale > 0
      abort "Schedules are not fully rebuilt at version #{current}. Run loans:rebuild_schedules."
    end

    puts "All schedules are at the current algorithm version."
  end

  desc "Rebuild loan amortization schedules in bounded, rate-limited batches"
  task :rebuild_schedules, [ :batch_size, :limit, :sleep ] => :environment do |_, args|
    batch_size = [ loan_task_option.call(args, :batch_size, "100").to_i, 1 ].max
    limit = loan_task_option.call(args, :limit)&.to_i
    pause = loan_task_option.call(args, :sleep, "0").to_f
    rebuilt = 0

    scope = loan_rebuild_scope.call
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
