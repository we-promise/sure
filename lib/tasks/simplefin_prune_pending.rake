# frozen_string_literal: true

# Maintenance task to prune pending transactions from the SimpleFin cumulative
# raw_transactions_payload store.
#
# Why: SimplefinAccount#raw_transactions_payload accumulates transactions across syncs
# and is never pruned. When pending inclusion is disabled, the API stops returning pending
# rows but ones already stored here keep getting (re)created as entries on every sync -
# including ones a user manually deleted. SimplefinEntry::Processor now skips pending rows
# while pending is disabled, but the stale rows remain in the store. This task removes them.
#
# Pending detection delegates to SimplefinEntry::Processor.pending?:
#   - pending: true (explicit flag), OR
#   - posted == 0 (epoch) AND transacted_at present (implicit pattern from some banks)
#
# Usage examples:
#   # Preview (no writes) across all SimpleFin accounts
#   bin/rails 'sure:simplefin:prune_pending[dry_run=true]'
#
#   # Execute across all SimpleFin accounts (writes enabled)
#   bin/rails 'sure:simplefin:prune_pending[dry_run=false]'
#
#   # Limit to one item or one linked account
#   bin/rails 'sure:simplefin:prune_pending[item_id=ec255931-62ff-4a68-abda-16067fad0429,dry_run=false]'
#   bin/rails 'sure:simplefin:prune_pending[account_id=8b46387c-5aa4-4a92-963a-4392c10999c9,dry_run=false]'

namespace :sure do
  namespace :simplefin do
    desc "Prune pending transactions from SimpleFin raw_transactions_payload. Args (named): item_id, account_id, dry_run=true"
    task :prune_pending, [ :item_id, :account_id, :dry_run ] => :environment do |_, args|
      # Support both positional and named (key=value) args; prefer named.
      kv = {}
      [ args[:item_id], args[:account_id], args[:dry_run] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      # A key=value string only carries a named arg, so it must not also be reused as a
      # positional fallback (otherwise `prune_pending[dry_run=true]` lands "dry_run=true"
      # in the :item_id slot and fails UUID validation).
      positional = ->(raw) { raw.is_a?(String) && raw.include?("=") ? nil : raw }

      item_id    = (kv["item_id"] || positional.call(args[:item_id])).presence
      account_id = (kv["account_id"] || positional.call(args[:account_id])).presence
      dry_raw    = (kv["dry_run"] || positional.call(args[:dry_run])).to_s.downcase

      # Default to dry_run=true unless explicitly disabled, and validate input strictly
      if dry_raw.blank? || %w[1 true yes y].include?(dry_raw)
        dry_run = true
      elsif %w[0 false no n].include?(dry_raw)
        dry_run = false
      else
        puts({ ok: false, error: "invalid_argument", message: "dry_run must be one of: true/yes/1 or false/no/0" }.to_json)
        exit 1
      end

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
        SimplefinItem.find(item_id).simplefin_accounts
      elsif account_id.present?
        acct = Account.find(account_id)
        # Prefer new provider linkage, fallback to legacy foreign key
        sfa = if acct.account_providers.where(provider_type: "SimplefinAccount").exists?
          AccountProvider.find_by(account: acct, provider_type: "SimplefinAccount")&.provider
        else
          SimplefinAccount.find_by(account: acct)
        end
        SimplefinAccount.where(id: Array.wrap(sfa).compact.map(&:id))
      else
        SimplefinAccount.all
      end

      total_accounts = 0
      total_removed = 0

      sfas.find_each do |sfa|
        txns = sfa.raw_transactions_payload.to_a
        kept = txns.reject { |tx| SimplefinEntry::Processor.pending?(tx) }
        removed = txns.size - kept.size
        next if removed.zero?

        total_accounts += 1
        total_removed += removed

        sfa.update!(raw_transactions_payload: kept) unless dry_run

        puts({ sfa_id: sfa.id, name: sfa.name, total: txns.size, removed: removed, kept: kept.size, dry_run: dry_run }.to_json)
      end

      puts({ ok: true, accounts_pruned: total_accounts, transactions_removed: total_removed, dry_run: dry_run }.to_json)
    end
  end
end
