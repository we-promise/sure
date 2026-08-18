# frozen_string_literal: true

# Reads every tracked address, then reprocesses only the rows whose on-chain
# state actually changed. An idle wallet costs reads and nothing else: no
# holdings, entries or balances are rewritten, and no account syncs are queued.
class OnchainWalletItem::Syncer
  include SyncStats::Collector

  attr_reader :onchain_wallet_item

  def initialize(onchain_wallet_item)
    @onchain_wallet_item = onchain_wallet_item
  end

  def perform_sync(sync)
    result = onchain_wallet_item.import_latest_onchain_data
    onchain_wallet_item.update!(status: :good) if onchain_wallet_item.requires_update?

    collect_setup_stats(sync, provider_accounts: onchain_wallet_item.onchain_wallet_accounts.to_a)

    changed = linked_accounts.where(id: result[:changed_account_ids]).to_a
    return if changed.empty?

    onchain_wallet_item.process_accounts(changed)

    account_ids = changed.filter_map { |onchain_account| onchain_account.current_account&.id }
    onchain_wallet_item.schedule_account_syncs(
      accounts: Account.where(id: account_ids),
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    return if account_ids.empty?

    collect_trades_stats(sync, account_ids: account_ids, source: OnchainWalletAccount::Processor::SOURCE)
    collect_transaction_stats(sync, account_ids: account_ids, source: OnchainWalletAccount::Processor::SOURCE)
  rescue StandardError => e
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "On-chain wallet sync failed: #{e.class}",
      source: self.class.name,
      provider_key: "onchain_wallet",
      family: onchain_wallet_item.family,
      metadata: { onchain_wallet_item_id: onchain_wallet_item.id, error: e.message }
    )
    mark_failed(sync, e.message)
    raise
  end

  # Runs for every linked asset, not just the ones that changed on chain: what
  # changed here is the price history, which no chain read can tell us about.
  def perform_post_sync
    linked_accounts.each do |onchain_account|
      OnchainWalletAccount::Processor.new(onchain_account).repair_display_only_movements
    rescue StandardError => e
      Rails.logger.warn("OnchainWalletItem::Syncer - movement repair failed for #{onchain_account.id}: #{e.class}")
    end
  end

  private
    def linked_accounts
      onchain_wallet_item.onchain_wallet_accounts.linked.joins(:account).merge(Account.visible)
    end

    def mark_failed(sync, error_message)
      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?

      if sync.respond_to?(:may_fail?) && sync.may_fail?
        sync.fail!
      elsif sync.respond_to?(:status)
        sync.update!(status: :failed)
      end

      sync.update!(error: error_message) if sync.respond_to?(:error)
    end
end
