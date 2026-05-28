# frozen_string_literal: true

class OnchainWalletItem::Syncer
  include SyncStats::Collector

  attr_reader :onchain_wallet_item

  def initialize(onchain_wallet_item)
    @onchain_wallet_item = onchain_wallet_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Importing on-chain wallets") if sync.respond_to?(:status_text)
    onchain_wallet_item.import_latest_onchain_wallet_data
    onchain_wallet_item.update!(status: :good) if onchain_wallet_item.requires_update?

    provider_accounts = onchain_wallet_item.onchain_wallet_accounts.to_a
    collect_setup_stats(sync, provider_accounts: provider_accounts)

    linked = onchain_wallet_item.onchain_wallet_accounts.joins(:account).merge(Account.visible)
    return unless linked.any?

    sync.update!(status_text: "Processing on-chain wallet accounts") if sync.respond_to?(:status_text)
    onchain_wallet_item.process_accounts

    onchain_wallet_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    collect_transaction_stats(sync, account_ids: linked.map { |wallet_account| wallet_account.current_account&.id }.compact, source: "onchain_wallet")
  rescue Provider::Etherscan::AuthenticationError, Provider::Etherscan::RateLimitError => e
    onchain_wallet_item.update!(status: :requires_update)
    mark_failed(sync, e.message)
    raise
  rescue StandardError => e
    Rails.logger.error "OnchainWalletItem::Syncer - unexpected error during sync: #{e.message}"
    mark_failed(sync, e.message)
    raise
  end

  def perform_post_sync
  end

  private
    def mark_failed(sync, error_message)
      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?
      sync.fail! if sync.respond_to?(:may_fail?) && sync.may_fail?
      sync.update!(status: :failed) if sync.respond_to?(:status) && sync.status != "failed"
      sync.update!(error: error_message) if sync.respond_to?(:error)
      sync.update!(status_text: error_message) if sync.respond_to?(:status_text)
    end
end
