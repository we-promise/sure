# frozen_string_literal: true

# Backfill and maintenance tasks for SimpleFin transactions metadata and demo cleanup
#
# Usage examples:
#   # Preview (no writes) a 45-day backfill for a single item
#   # NOTE: Use your real item id
#   bin/rails 'sure:simplefin:backfill_extra[item_id=ec255931-62ff-4a68-abda-16067fad0429,days=45,dry_run=true]'
#
#   # Execute the backfill (writes enabled)
#   bin/rails 'sure:simplefin:backfill_extra[item_id=ec255931-62ff-4a68-abda-16067fad0429,days=45,dry_run=false]'
#
#   # Limit to a single linked account by Account ID (UUID from your UI/db)
#   bin/rails 'sure:simplefin:backfill_extra[account_id=8b46387c-5aa4-4a92-963a-4392c10999c9,days=30,dry_run=false]'
#
#   # Clean up known demo entries for a specific account (dry-run first)
#   bin/rails 'sure:simplefin:cleanup_demo_entries[account_id=8b46387c-5aa4-4a92-963a-4392c10999c9,dry_run=true]'
#   bin/rails 'sure:simplefin:cleanup_demo_entries[account_id=8b46387c-5aa4-4a92-963a-4392c10999c9,dry_run=false]'

namespace :sure do
  namespace :simplefin do
    desc "Backfill transactions.extra for SimpleFin imports over a recent window. Args (named): item_id, account_id, days=30, dry_run=true, force=false"
    task :backfill_extra, [ :item_id, :account_id, :days, :dry_run, :force ] => :environment do |_, args|
      # Support both positional and named (key=value) args; prefer named
      kv = {}
      [ args[:item_id], args[:account_id], args[:days], args[:dry_run], args[:force] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      item_id    = (kv["item_id"] || args[:item_id]).presence
      account_id = (kv["account_id"] || args[:account_id]).presence
      days_i     = (kv["days"] || args[:days] || 30).to_i
      dry_raw    = (kv["dry_run"] || args[:dry_run]).to_s.downcase
      force_raw  = (kv["force"] || args[:force]).to_s.downcase

      # Default to dry_run=true unless explicitly disabled
      dry_run = dry_raw.blank? ? true : %w[1 true yes y].include?(dry_raw)
      force   = %w[1 true yes y].include?(force_raw)
      days_i = 30 if days_i <= 0

      window_start = days_i.days.ago.to_date
      window_end   = Date.today

      # Basic UUID validation when provided
      uuid_rx = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      if item_id.present? && !item_id.match?(uuid_rx)
        puts({ ok: false, error: "invalid_argument", message: "item_id must be a hyphenated UUID" }.to_json)
        exit 1
      end
      if account_id.present? && !account_id.match?(uuid_rx)
        puts({ ok: false, error: "invalid_argument", message: "account_id must be a hyphenated UUID" }.to_json)
        exit 1
      end

      # Select SimplefinAccounts to process
      sfas = if item_id.present?
        item = SimplefinItem.find(item_id)
        item.simplefin_accounts
      elsif account_id.present?
        acct = Account.find(account_id)
        # Prefer new provider linkage, fallback to legacy foreign key
        sfa = if acct.account_providers.where(provider_type: "SimplefinAccount").exists?
          AccountProvider.find_by(account: acct, provider_type: "SimplefinAccount")&.provider
        else
          SimplefinAccount.find_by(account: acct)
        end
        Array.wrap(sfa)
      else
        puts({ ok: false, error: "usage", message: "Provide item_id or account_id" }.to_json)
        exit 1
      end

      total_seen = 0
      total_matched = 0
      total_updated = 0
      total_skipped = 0
      total_errors = 0

      sfas.find_each do |sfa|
        acct = sfa.current_account
        unless acct
          puts({ warn: "no_linked_account", sfa_id: sfa.id, name: sfa.name }.to_json)
          next
        end

        txs = Array(sfa.raw_transactions_payload).map { |t| t.with_indifferent_access }
        if txs.empty?
          puts({ info: "no_raw_transactions", sfa_id: sfa.id, name: sfa.name }.to_json)
          next
        end

        txs.each do |t|
          begin
            posted = t[:posted]
            trans  = t[:transacted_at]

            # convert to Date where possible for window filtering
            posted_d = case posted
            when String then Date.parse(posted) rescue nil
            when Numeric then Time.zone.at(posted).to_date rescue nil
            when Date then posted
            when Time, DateTime then posted.to_date
            else nil
            end
            trans_d  = case trans
            when String then Date.parse(trans) rescue nil
            when Numeric then Time.zone.at(trans).to_date rescue nil
            when Date then trans
            when Time, DateTime then trans.to_date
            else nil
            end

            best = posted_d || trans_d
            # If neither date is available, skip (cannot window-match safely)
            if best.nil? || best < window_start || best > window_end
              total_skipped += 1
              next
            end

            total_seen += 1

            # Build extra payload exactly like SimplefinEntry::Processor
            sf = {}
            sf["payee"] = t[:payee] if t.key?(:payee)
            sf["memo"] = t[:memo] if t.key?(:memo)
            sf["description"] = t[:description] if t.key?(:description)
            sf["extra"] = t[:extra] if t[:extra].is_a?(Hash)
            extra_hash = sf.empty? ? nil : { "simplefin" => sf }

            # Skip if no metadata to add (unless forcing overwrite)
            if extra_hash.nil? && !force
              total_skipped += 1
              next
            end

            # Reuse the import adapter path so we merge onto the existing entry
            adapter = Account::ProviderImportAdapter.new(acct)
            external_id = "simplefin_#{t[:id]}"

            if dry_run
              # Simulate: check if we can composite-match; we won't persist
              entry = acct.entries.find_by(external_id: external_id, source: "simplefin")
              entry ||= adapter.composite_match(source: "simplefin", name: SimplefinEntry::Processor.new(t, simplefin_account: sfa).send(:name), amount: SimplefinEntry::Processor.new(t, simplefin_account: sfa).send(:amount), date: (posted_d || trans_d), window_days: (acct.accountable_type.in?([ "CreditCard", "Loan" ]) ? 5 : 3))
              matched = entry.present?
              total_matched += 1 if matched
            else
              processed = SimplefinEntry::Processor.new(t, simplefin_account: sfa).process
              if processed&.transaction&.extra.present?
                total_updated += 1
              else
                total_skipped += 1
              end
            end
          rescue => e
            total_errors += 1
            puts({ error: e.class.name, message: e.message }.to_json)
          end
        end

        puts({ sfa_id: sfa.id, account_id: acct.id, name: sfa.name, seen: total_seen, matched: total_matched, updated: total_updated, skipped: total_skipped, errors: total_errors, window_start: window_start, window_end: window_end, dry_run: dry_run, force: force }.to_json)
      end

      puts({ ok: true, total_seen: total_seen, total_matched: total_matched, total_updated: total_updated, total_skipped: total_skipped, total_errors: total_errors, window_start: window_start, window_end: window_end, dry_run: dry_run, force: force }.to_json)
    end

    desc "List and optionally delete known demo SimpleFin entries for a given Account. Args (named): account_id, dry_run=true, pattern"
    task :cleanup_demo_entries, [ :account_id, :dry_run, :pattern ] => :environment do |_, args|
      kv = {}
      [ args[:account_id], args[:dry_run], args[:pattern] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      account_id = (kv["account_id"] || args[:account_id]).presence
      dry_raw     = (kv["dry_run"] || args[:dry_run]).to_s.downcase
      pattern     = (kv["pattern"] || args[:pattern]).presence || "simplefin_posted_demo_%|simplefin_posted_ui"

      dry_run = %w[1 true yes y].include?(dry_raw)

      unless account_id.present?
        puts({ ok: false, error: "usage", message: "Provide account_id" }.to_json)
        exit 1
      end

      acct = Account.find(account_id)

      patterns = pattern.split("|")
      scope = acct.entries.where(source: "simplefin", entryable_type: "Transaction")
      # Apply LIKE filters combined with OR
      like_sql = patterns.map { |p| "external_id LIKE ?" }.join(" OR ")
      like_vals = patterns.map { |p| p }
      candidates = scope.where(like_sql, *like_vals)

      out = candidates.order(date: :desc).map { |e| { id: e.id, external_id: e.external_id, date: e.date, name: e.name, amount: e.amount } }
      puts({ account_id: acct.id, count: candidates.count, entries: out }.to_json)

      if candidates.any? && !dry_run
        deleted = 0
        ActiveRecord::Base.transaction do
          candidates.each do |e|
            e.destroy!
            deleted += 1
          end
        end
        puts({ ok: true, deleted: deleted }.to_json)
      else
        puts({ ok: true, deleted: 0, dry_run: dry_run }.to_json)
      end
    end
  end
end
