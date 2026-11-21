# frozen_string_literal: true

namespace :securities do
  # What a merge moved, and the rule it applied where holdings collided.
  merge_summary = lambda do |counts|
    "#{counts[:holdings_moved]} holdings moved, #{counts[:holdings_removed]} colliding holdings removed " \
      "(the more recently written row is kept), #{counts[:trades]} trades, #{counts[:lots]} lots, " \
      "#{counts[:references]} references"
  end

  # Rows that point at a security without being its own: lot origins and
  # provider securities of remapped holdings. A merge re-points them too.
  reference_count = lambda do |security_ids|
    HoldingLot.where(origin_security_id: security_ids).count + Holding.where(provider_security_id: security_ids).count
  end

  desc "De-duplicate securities based on ticker + exchange_operating_mic"
  task :deduplicate, [ :dry_run ] => :environment do |_t, args|
    dry_run = args[:dry_run].present?
    puts "Starting securities de-duplication... #{dry_run ? '(DRY RUN)' : ''}"

    # First handle securities without exchange_operating_mic
    securities_without_mic = Security.where(exchange_operating_mic: nil).where.not(ticker: nil)
    puts "\nFound #{securities_without_mic.count} securities without exchange_operating_mic"

    securities_without_mic.find_each do |security|
      # Find if there's a security with the same ticker that has an exchange_operating_mic
      canonical = Security.where.not(exchange_operating_mic: nil)
                        .where(ticker: security.ticker)
                        .order(created_at: :asc)
                        .first

      if canonical
        puts "\nProcessing #{security.ticker} (no MIC):"
        puts "  Canonical: #{canonical.id} (created: #{canonical.created_at}, MIC: #{canonical.exchange_operating_mic})"
        puts "  Duplicate without MIC: #{security.id}"

        # Count affected records
        holdings_count = Holding.where(security_id: security.id).count
        trades_count = Trade.where(security_id: security.id).count
        prices_count = Security::Price.where(security_id: security.id).count
        lots_count = HoldingLot.where(security_id: security.id).count
        references_count = reference_count.call(security.id)

        puts "  Would update:"
        puts "    - #{holdings_count} holdings"
        puts "    - #{trades_count} trades"
        puts "    - #{prices_count} prices"
        puts "    - #{lots_count} lots"
        puts "    - #{references_count} references"

        unless dry_run
          begin
            # Moves everything that references the duplicate, lots and splits
            # included, deletes it and syncs the affected accounts.
            counts = Security::Merger.merge_group!([ security ], into: canonical)
            puts "  ✓ Successfully merged and removed duplicate: #{merge_summary.call(counts)}"
          rescue => e
            puts "  ✗ Error processing #{security.ticker}: #{e.message}"
          end
        end
      end
    end

    # Now handle duplicates with same ticker + exchange_operating_mic
    duplicates = Security
      .where.not(ticker: nil)
      .where.not(exchange_operating_mic: nil)
      .group(:ticker, :exchange_operating_mic)
      .having("COUNT(*) > 1")
      .pluck(:ticker, :exchange_operating_mic)

    puts "\nFound #{duplicates.length} sets of duplicate securities with same ticker + MIC"
    total_holdings = 0
    total_trades = 0
    total_prices = 0
    total_lots = 0
    total_references = 0

    duplicates.each do |ticker, exchange_operating_mic|
      securities = Security.where(ticker: ticker, exchange_operating_mic: exchange_operating_mic)
        .order(created_at: :asc)

      canonical = securities.first
      duplicates = securities[1..]

      puts "\nProcessing #{ticker} (#{exchange_operating_mic}):"
      puts "  Canonical: #{canonical.id} (created: #{canonical.created_at})"
      puts "  Duplicates: #{duplicates.map(&:id).join(', ')}"

      # Count affected records
      holdings_count = Holding.where(security_id: duplicates).count
      trades_count = Trade.where(security_id: duplicates).count
      prices_count = Security::Price.where(security_id: duplicates).count
      lots_count = HoldingLot.where(security_id: duplicates).count
      references_count = reference_count.call(duplicates.map(&:id))

      total_holdings += holdings_count
      total_trades += trades_count
      total_prices += prices_count
      total_lots += lots_count
      total_references += references_count

      puts "  Would update:"
      puts "    - #{holdings_count} holdings"
      puts "    - #{trades_count} trades"
      puts "    - #{prices_count} prices"
      puts "    - #{lots_count} lots"
      puts "    - #{references_count} references"

      unless dry_run
        begin
          # The whole group in one transaction: it merges whole or not at all.
          counts = Security::Merger.merge_group!(duplicates, into: canonical)
          puts "  ✓ Successfully merged and removed duplicates: #{merge_summary.call(counts)}"
        rescue => e
          puts "  ✗ Error processing #{ticker}: #{e.message}"
        end
      end
    end

    puts "\nSummary:"
    puts "  Total duplicate sets: #{duplicates.length}"
    puts "  Total affected records:"
    puts "    - #{total_holdings} holdings"
    puts "    - #{total_trades} trades"
    puts "    - #{total_prices} prices"
    puts "    - #{total_lots} lots"
    puts "    - #{total_references} references"
    puts "  Mode: #{dry_run ? 'Dry run (no changes made)' : 'Live run (changes applied)'}"
    puts "\nDe-duplication complete!"
  end

  desc "Relabel Warsaw (XWAR/WAR) security_prices wrongly stored as USD to PLN. Args: dry_run (default true)"
  task :backfill_warsaw_price_currency, [ :dry_run ] => :environment do |_t, args|
    raw_dry = args[:dry_run].presence || ENV["DRY_RUN"].presence
    dry_run = case raw_dry.to_s.strip.downcase
    when "0", "false", "no", "n" then false
    when "1", "true", "yes", "y" then true
    when "" then true
    else
      true
    end

    puts "Warsaw price currency backfill (dry_run: #{dry_run})..."
    result = Security::WarsawPriceCurrencyBackfill.new(dry_run: dry_run, sync_accounts: !dry_run).call
    puts result.to_h.to_json
  end
end
