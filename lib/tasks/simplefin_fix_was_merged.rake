# frozen_string_literal: true

require Rails.root.join("lib/simplefin/date_utils").to_s

# Fix and optionally recompute was_merged flags for a specific Account over a recent window
#
# Usage:
#   # Preview only (no writes):
#   # Quicksilver example
#   # bin/rails 'sure:simplefin:fix_was_merged[account_id=d2043ec1-f227-402f-a8bb-5a6ac486b66a,days=45,dry_run=true]'
#
#   # Apply fixes (clear and recompute):
#   # bin/rails 'sure:simplefin:fix_was_merged[account_id=d2043ec1-f227-402f-a8bb-5a6ac486b66a,days=45,dry_run=false]'
#
# Args (named or positional key=value):
#   account_id: UUID of the Account
#   days:       Window size in days back from today (default 30)
#   dry_run:    true|false (default true)
#   recompute:  true|false (default true) — if true, reprocess SimpleFin raw payload to restore legitimate flags
#
namespace :sure do
  namespace :simplefin do
    desc "Clear and optionally recompute transaction.was_merged for a given account and date window"
    task :fix_was_merged, [ :account_id, :days, :dry_run, :recompute ] => :environment do |_, args|
      kv = {}
      [ args[:account_id], args[:days], args[:dry_run], args[:recompute] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      account_id = (kv["account_id"] || args[:account_id]).presence
      days_i     = (kv["days"] || args[:days] || 30).to_i
      dry_raw    = (kv["dry_run"] || args[:dry_run]).to_s.downcase
      reco_raw   = (kv["recompute"] || args[:recompute]).to_s.downcase

      # Default to dry_run=true unless explicitly disabled
      dry_run   = dry_raw.blank? ? true : %w[1 true yes y].include?(dry_raw)
      recompute = reco_raw.blank? ? true : %w[1 true yes y].include?(reco_raw)
      days_i = 30 if days_i <= 0

      unless account_id.present?
        puts({ ok: false, error: "usage", message: "Provide account_id" }.to_json)
        exit 1
      end

      # Basic UUID validation
      uuid_rx = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      unless account_id.match?(uuid_rx)
        puts({ ok: false, error: "invalid_argument", message: "account_id must be a hyphenated UUID" }.to_json)
        exit 1
      end

      acct = Account.find(account_id)
      window_start = days_i.days.ago.to_date
      window_end   = Date.today

      # Select entries in window
      entries_scope = acct.entries.where(entryable_type: "Transaction").where(date: window_start..window_end)

      total = entries_scope.count
      with_flag = entries_scope.joins("JOIN transactions ON transactions.id = entries.entryable_id")
                                .where("transactions.was_merged = ?", true)
                                .count

      puts({ account_id: acct.id, window_start: window_start, window_end: window_end, total: total, currently_merged: with_flag, dry_run: dry_run }.to_json)

      cleared = 0
      updated = 0
      errors  = 0

      unless dry_run
        ActiveRecord::Base.transaction do
          # Clear flags first
          entries_scope.includes(:entryable).find_each do |e|
            t = e.entryable
            next unless t.is_a?(Transaction)
            next unless t.respond_to?(:was_merged)

            if t.was_merged
              t.update!(was_merged: false)
              cleared += 1
            end
          end

          if recompute
            # Try to reprocess SimpleFin raw payload for the linked SimplefinAccount
            sfa = begin
              # Prefer AccountProvider linkage
              ap = acct.account_providers.where(provider_type: "SimplefinAccount").first
              ap&.provider
            rescue StandardError
              nil
            end

            sfa ||= SimplefinAccount.find_by(account: acct)

            if sfa && sfa.raw_transactions_payload.present?
              txs = Array(sfa.raw_transactions_payload).map { |t| t.with_indifferent_access }
              txs.each do |t|
                begin
                  posted_d = Simplefin::DateUtils.parse_provider_date(t[:posted])
                  trans_d  = Simplefin::DateUtils.parse_provider_date(t[:transacted_at])
                  best = posted_d || trans_d
                  next if best.nil? || best < window_start || best > window_end

                  # Re-run processor (idempotent); current heuristics will set was_merged where appropriate
                  SimplefinEntry::Processor.new(t, simplefin_account: sfa).process
                  updated += 1
                rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
                  errors += 1
                  puts({ warn: "recompute_error", message: e.message, tx_id: t[:id] }.to_json)
                rescue ArgumentError, TypeError => e
                  errors += 1
                  puts({ warn: "recompute_parse_error", message: e.message, tx_id: t[:id] }.to_json)
                end
              end
            else
              puts({ info: "no_raw_transactions", message: "Unable to recompute without raw SimpleFin payload" }.to_json)
            end
          end
        end
      end

      puts({ ok: true, cleared: cleared, recomputed: updated, errors: errors, window_start: window_start, window_end: window_end, dry_run: dry_run }.to_json)
    end
  end
end
