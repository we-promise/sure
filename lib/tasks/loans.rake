namespace :loans do
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
