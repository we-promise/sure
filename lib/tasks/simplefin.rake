# frozen_string_literal: true

namespace :sure do
  namespace :simplefin do
    desc "Print debug info for a SimpleFin item: latest sync, snapshot accounts, simplefin_accounts, and unlinked list"
    task :debug, [ :item_id ] => :environment do |_, args|
      unless args[:item_id].present?
        puts({ error: "usage", example: "bin/rails sure:simplefin:debug[ITEM_ID]" }.to_json)
        exit 1
      end

      item = SimplefinItem.find(args[:item_id])
      latest_sync = item.syncs.order(created_at: :desc).first
      # Our model stores the latest snapshot directly on the item (`raw_payload`).
      snapshot_accounts = item.raw_payload&.dig(:accounts)&.size
      unlinked = item.simplefin_accounts.left_joins(:account).where(accounts: { id: nil })

      out = {
        item_id: item.id,
        name: item.name,
        last_synced_at: item.last_synced_at,
        latest_sync: latest_sync&.attributes&.slice("id", "status", "error", "status_text", "created_at", "completed_at"),
        snapshot_accounts: snapshot_accounts,
        simplefin_accounts_count: item.simplefin_accounts.count,
        unlinked_count: unlinked.count,
        unlinked: unlinked.limit(20).map { |sfa| { id: sfa.id, upstream_id: sfa.account_id, name: sfa.name } }
      }

      puts out.to_json
    rescue => e
      puts({ error: e.class.name, message: e.message, backtrace: e.backtrace&.take(3) }.to_json)
      exit 1
    end
  end
end
