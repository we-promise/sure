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
