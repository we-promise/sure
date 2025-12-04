# frozen_string_literal: true

# Backfill holdings for SimpleFin-linked investment accounts using the existing
# SimplefinAccount::Investments::HoldingsProcessor. This is provider-agnostic at the
# UI/model level and works for any brokerage piped through SimpleFin (including Robinhood).
#
# Examples:
#   # By SimpleFin item id (process all linked accounts under the item)
#   # bin/rails 'sure:simplefin:backfill_holdings[item_id=ec255931-62ff-4a68-abda-16067fad0429,dry_run=true]'
#   # Apply:
#   # bin/rails 'sure:simplefin:backfill_holdings[item_id=ec255931-62ff-4a68-abda-16067fad0429,dry_run=false]'
#
#   # By Account name contains (e.g., "Robinhood")
#   # bin/rails 'sure:simplefin:backfill_holdings[account_name=Robinhood,dry_run=true]'
#
#   # By Account id (UUID in your DB)
#   # bin/rails 'sure:simplefin:backfill_holdings[account_id=<ACCOUNT_UUID>,dry_run=false]'
#
# Args (named or positional key=value):
#   item_id      - SimplefinItem id
#   account_id   - Account id (we will find its linked SimplefinAccount)
#   account_name - Case-insensitive contains match to pick a single Account
#   dry_run      - default true; when true, do not write, just report what would be processed
#   sleep_ms     - per-account sleep to be polite to quotas (default 200ms)

namespace :sure do
  namespace :simplefin do
    desc "Backfill holdings for SimpleFin-linked investment accounts. Args: item_id, account_id, account_name, dry_run=true, sleep_ms=200"
    task :backfill_holdings, [ :item_id, :account_id, :account_name, :dry_run, :sleep_ms ] => :environment do |_, args|
      kv = {}
      [ args[:item_id], args[:account_id], args[:account_name], args[:dry_run], args[:sleep_ms] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      # Prefer named args parsed into kv; fall back to positional only when it is not a key=value string
      fetch = ->(sym_key, str_key) do
        if kv.key?(str_key)
          kv[str_key]
        else
          v = args[sym_key]
          v.is_a?(String) && v.include?("=") ? nil : v
        end
      end

      item_id      = fetch.call(:item_id, "item_id").presence
      account_id   = fetch.call(:account_id, "account_id").presence
      account_name = fetch.call(:account_name, "account_name").presence
      dry_raw      = (kv["dry_run"] || args[:dry_run]).to_s.downcase
      sleep_ms     = ((kv["sleep_ms"] || args[:sleep_ms] || 200).to_i).clamp(0, 5000)

      # Default to dry_run=true unless explicitly disabled, and validate input strictly
      if dry_raw.blank?
        dry_run = true
      elsif %w[1 true yes y].include?(dry_raw)
        dry_run = true
      elsif %w[0 false no n].include?(dry_raw)
        dry_run = false
      else
        puts({ ok: false, error: "invalid_argument", message: "dry_run must be one of: true/yes/1 or false/no/0" }.to_json)
        exit 1
      end

      # Select SimplefinAccounts to process
      sfas = []

      if item_id.present?
        begin
          item = SimplefinItem.find(item_id)
          sfas = item.simplefin_accounts.joins(:account)
        rescue ActiveRecord::RecordNotFound
          puts({ ok: false, error: "not_found", message: "SimplefinItem not found", item_id: item_id }.to_json)
          exit 1
        end
      elsif account_id.present?
        begin
          acct = Account.find(account_id)
          ap = acct.account_providers.where(provider_type: "SimplefinAccount").first
          sfa = ap&.provider || SimplefinAccount.find_by(account: acct)
          sfas = Array.wrap(sfa).compact
        rescue ActiveRecord::RecordNotFound
          puts({ ok: false, error: "not_found", message: "Account not found", account_id: account_id }.to_json)
          exit 1
        end
      elsif account_name.present?
        sanitized = ActiveRecord::Base.sanitize_sql_like(account_name.to_s.downcase)
        acct = Account.where("LOWER(name) LIKE ?", "%#{sanitized}%")
                      .order(updated_at: :desc)
                      .first
        unless acct
          puts({ ok: false, error: "not_found", message: "No Account matched", account_name: account_name }.to_json)
          exit 1
        end
        ap = acct.account_providers.where(provider_type: "SimplefinAccount").first
        sfa = ap&.provider || SimplefinAccount.find_by(account: acct)
        sfas = Array.wrap(sfa).compact
      else
        puts({ ok: false, error: "usage", message: "Provide one of item_id, account_id, or account_name" }.to_json)
        exit 1
      end
      total_accounts = 0
      total_holdings_seen = 0
      total_holdings_written = 0
      errors = []

      sfas.each do |sfa|
        begin
          account = sfa.current_account
          next unless [ "Investment", "Crypto" ].include?(account&.accountable_type)

          total_accounts += 1
          holdings_data = Array(sfa.raw_holdings_payload)

          if holdings_data.empty?
            puts({ info: "no_raw_holdings", sfa_id: sfa.id, account_id: account.id, name: sfa.name }.to_json)
            next
          end

          count = holdings_data.size
          total_holdings_seen += count

          if dry_run
            puts({ dry_run: true, sfa_id: sfa.id, account_id: account.id, name: sfa.name, would_process: count }.to_json)
          else
            SimplefinHoldingsApplyJob.perform_later(sfa.id)
            total_holdings_written += count
            puts({ ok: true, sfa_id: sfa.id, account_id: account.id, name: sfa.name, enqueued: true, estimated_holdings: count }.to_json)
          end

          sleep(sleep_ms / 1000.0) if sleep_ms.positive?
        rescue => e
          errors << { sfa_id: sfa.id, error: e.class.name, message: e.message }
        end
      end

      puts({ ok: true, accounts_processed: total_accounts, holdings_seen: total_holdings_seen, holdings_written: total_holdings_written, errors: errors }.to_json)
    end
  end
end
