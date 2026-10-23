namespace :snaptrade do
  # Repairs SnapTrade positions split across two Security rows of one ticker
  # before #3999: moves each account's trades and holdings onto the row the
  # account holds, then re-materializes. Per account, never
  # destroys a Security and never moves a price.
  #
  #   bin/rails snaptrade:repair_split_securities               # dry run, every SnapTrade account
  #   bin/rails "snaptrade:repair_split_securities[ACCOUNT_ID]" # dry run, one account
  #   DRY_RUN=false bin/rails snaptrade:repair_split_securities # writes
  #
  # A ticker whose rows name different exchanges is two listings, so it is
  # skipped and listed for review. A live run refuses an account whose target
  # row lacks a split its source rows have, one whose target row lacks
  # prices its source rows have, and one with a SnapTrade sync or activities
  # fetch pending or running. ALLOW_PRICE_GAPS=true overrides the price
  # check only, and only with an account id:
  #   DRY_RUN=false ALLOW_PRICE_GAPS=true bin/rails "snaptrade:repair_split_securities[ACCOUNT_ID]"
  #
  # The task exits non-zero when any account was refused or failed, or when
  # it is run with ALLOW_PRICE_GAPS and no account id. A failure inside the
  # repair rolls that account back; one while reporting on it comes after the
  # repair has committed, and says so.
  desc "Repair SnapTrade holdings and trades split across duplicate security rows (dry run unless DRY_RUN=false)"
  task :repair_split_securities, [ :account_id ] => :environment do |_, args|
    dry_run = ENV["DRY_RUN"].to_s.strip.downcase != "false"
    allow_price_gaps = ENV["ALLOW_PRICE_GAPS"].to_s.strip.downcase == "true"
    if allow_price_gaps && args[:account_id].blank?
      abort "ALLOW_PRICE_GAPS needs an account id: run it for one reviewed account at a time. Nothing written."
    end
    accounts = if args[:account_id].present?
      Account.where(id: args[:account_id])
    else
      SnaptradeAccount::SplitSecurityRepair.accounts
    end

    puts dry_run ? "DRY RUN: nothing will be written. Set DRY_RUN=false to apply." : "Applying repairs."

    describe = lambda do |securities, id|
      security = securities[id]
      exchange = security && (security.exchange_operating_mic.presence || security.exchange_mic.presence)
      "#{id} (#{exchange || 'no exchange'}, #{security&.name})"
    end

    refusals = []
    failures = []
    accounts.find_each do |account|
      repair = SnaptradeAccount::SplitSecurityRepair.new(account, dry_run: dry_run, allow_price_gaps: allow_price_gaps)
      unless repair.snaptrade_linked?
        puts "Account #{account.id} (#{account.name}): not a SnapTrade-linked account"
        next
      end

      repair_returned = false
      results = repair.run
      repair_returned = true
      securities = Security.where(id: results.flat_map { |result| [ result.target_id, *result.source_ids ] }).index_by(&:id)

      if results.empty? && repair.conflicts.empty?
        puts "Account #{account.id} (#{account.name}): no split securities"
        next
      end

      puts "Account #{account.id} (#{account.name}):"
      results.each do |result|
        sources = result.source_ids.map { |id| describe.call(securities, id) }.join(", ")
        puts "  #{result.ticker}: target #{describe.call(securities, result.target_id)} [#{result.target_source}], from #{sources}"
        puts "    trades moved: #{result.trades_moved}, holdings moved: #{result.holdings_moved}, " \
             "holdings dropped (target already had the date): #{result.holdings_dropped}, " \
             "calculated target holdings replaced by a SnapTrade snapshot: #{result.holdings_replaced}"

        if result.dropped_snapshots.any?
          dropped = result.dropped_snapshots.map { |date, cost_basis| "#{date.iso8601} (cost basis #{cost_basis || 'none'})" }
          puts "    SnapTrade snapshots dropped: #{dropped.join(', ')}"
        end

        if result.unmatched_split_dates.any?
          puts "    split history: source splits the target lacks, on #{result.unmatched_split_dates.map(&:iso8601).join(', ')}"
        end

        gaps = result.price_gap_dates
        next if gaps.empty?

        shown = gaps.first(10).map(&:iso8601).join(", ")
        shown += ", ..." if gaps.size > 10
        puts "    price gap: #{gaps.size} date(s) priced on another row but not the target: #{shown}"
      end

      repair.conflicts.each do |ticker, rows|
        listed = rows.map { |id, exchange| "#{id} (#{exchange || 'no exchange'})" }.join(", ")
        puts "  #{ticker}: skipped, rows on different exchanges are separate listings: #{listed}"
      end
    rescue SnaptradeAccount::SplitSecurityRepair::Refused => e
      puts "Account #{account.id} (#{account.name}): refused, nothing written: #{e.message}"
      refusals << account.id
    rescue StandardError => e
      outcome = if repair_returned
        dry_run ? "reporting failed, nothing written" : "repair applied, but reporting failed"
      else
        dry_run ? "failed, nothing written" : "failed, rolled back"
      end
      puts "Account #{account.id}: #{outcome}: #{e.class}: #{e.message}"
      Rails.logger.error("SnapTrade split security repair failed for account #{account.id}\n#{e.full_message(highlight: false)}")
      failures << account.id
    end

    problems = []
    problems << "Refused: #{refusals.size} account(s): #{refusals.join(', ')}" if refusals.any?
    problems << "Failed: #{failures.size} account(s): #{failures.join(', ')}" if failures.any?
    abort problems.join("; ") if problems.any?
  end
end
