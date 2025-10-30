# frozen_string_literal: true

namespace :sure do
  desc "Backfill transactions.was_merged for pending→posted merges. Args: dry_run, days_back (default 90)"
  task :backfill_was_merged, [ :dry_run, :days_back ] => :environment do |_, args|
    dry = case (args[:dry_run] || ENV["DRY_RUN"])&.to_s&.downcase
    when "1", "true", "yes", "y" then true
    else false
    end

    days_back = (args[:days_back] || ENV["DAYS_BACK"]).to_i
    days_back = 90 if days_back <= 0
    start_date = Date.today - days_back.days

    total_seen = 0
    total_flagged = 0

    NAME_STRIP_REGEX = /\b(visa|mastercard|card|debit|credit|payment|auth|pending|pos|bank|transaction)\b|[^a-z0-9]+/i.freeze
    normalize = ->(s) do
      base = s.to_s.downcase
      base = base.gsub(NAME_STRIP_REGEX, " ").squeeze(" ").strip
      base = base.gsub(/\b\d+\b/, " ").squeeze(" ").strip
      base
    end

    # For each account, attempt to find pairs that look like pending→posted under our composite rules
    Account.find_each do |account|
      scope = account.entries.where(entryable_type: "Transaction").where("date >= ?", start_date).order(:date)
      entries = scope.to_a
      next if entries.empty?

      by_norm = Hash.new { |h, k| h[k] = [] }
      entries.each do |e|
        by_norm[normalize.call(e.name)] << e
      end

      by_norm.each_value do |list|
        # Sliding comparisons; small lists expected per normalized name
        list.each_with_index do |e, i|
          ((i + 1)...list.length).each do |j|
            e2 = list[j]
            total_seen += 1
            # Tight date window and amount tolerance
            next unless (e.date - 3.days) <= e2.date && e2.date <= (e.date + 3.days)
            amt_diff = (BigDecimal(e.amount.to_s) - BigDecimal(e2.amount.to_s)).abs
            next unless amt_diff <= BigDecimal("0.01")
            # Same sign only (both inflow or both outflow)
            same_sign = (BigDecimal(e.amount.to_s) >= 0 && BigDecimal(e2.amount.to_s) >= 0) || (BigDecimal(e.amount.to_s) < 0 && BigDecimal(e2.amount.to_s) < 0)
            next unless same_sign

            # If neither is flagged yet, consider the earlier one as the merged-from pending hold
            target = e.date <= e2.date ? e : e2
            tx = target.entryable
            next unless tx.is_a?(Transaction)
            next if tx.was_merged # already flagged

            unless dry
              tx.update_columns(was_merged: true)
            end
            total_flagged += 1
            break
          end
        end
      end
    end

    puts({ ok: true, dry_run: dry, days_back: days_back, checked_pairs: total_seen, flagged: total_flagged }.to_json)
  rescue => e
    puts({ ok: false, error: e.class.name, message: e.message }.to_json)
    exit 1
  end
end


namespace :sure do
  desc "Clear transactions.was_merged flags. Args: dry_run, days_back (default 120), account_id (optional)"
  task :clear_was_merged, [ :dry_run, :days_back, :account_id ] => :environment do |_, args|
    dry = case (args[:dry_run] || ENV["DRY_RUN"])&.to_s&.downcase
    when "1", "true", "yes", "y" then true
    else false
    end

    days_back = (args[:days_back] || ENV["DAYS_BACK"]).to_i
    days_back = 120 if days_back <= 0
    start_date = Date.today - days_back.days

    scope = Entry.where(entryable_type: "Transaction").where("date >= ?", start_date)
                 .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
                 .where("transactions.was_merged = ?", true)

    if (aid = (args[:account_id] || ENV["ACCOUNT_ID"]).presence)
      scope = scope.where(account_id: aid)
    end

    tx_ids = scope.select(:entryable_id).distinct.pluck(:entryable_id)

    if dry
      puts({ ok: true, dry_run: true, days_back: days_back, affected_transactions: tx_ids.size, sample: tx_ids.first(10) }.to_json)
    else
      updated = Transaction.where(id: tx_ids).update_all(was_merged: false, updated_at: Time.current)
      puts({ ok: true, dry_run: false, days_back: days_back, cleared: updated }.to_json)
    end
  rescue => e
    puts({ ok: false, error: e.class.name, message: e.message }.to_json)
    exit 1
  end
end
